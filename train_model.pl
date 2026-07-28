#!/usr/bin/perl
# =============================================================================
# train_model.pl — Fase 4: Ridge Regression multi-output (v2 optimizado)
# =============================================================================
# PASO 0: Verificacion NaN + imputacion + flags missing + one-hot
# PASO 1: Grid de lambdas con split temporal 80/20 (pre-calcula XtX/Xty una vez)
# PASO 2: Seleccion lambda por MAE en sub-val temporal
# PASO 3: Reentrenamiento final sobre 100% de train + guardar models.json
# PASO 4: Prediccion sobre test + post-proceso (clip + monotonia)
# PASO 5: Evaluacion MAE/RMSE + guardar test_predictions.csv
# PASO 6: Validacion final obligatoria
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;
use File::Spec;
use Carp qw(carp croak);
use JSON::PP;

use Market::Concepts::DSVWAP::Ridge;

my $OUT_DIR     = File::Spec->catfile($Bin, 'output');
my $TRAIN_NORM  = File::Spec->catfile($OUT_DIR, 'train_features_normalized.csv');
my $TEST_NORM   = File::Spec->catfile($OUT_DIR, 'test_features_normalized.csv');
my $TEST_META   = File::Spec->catfile($OUT_DIR, 'test_metadata.csv');
my $MODELS_JSON = File::Spec->catfile($OUT_DIR, 'models.json');
my $TEST_PRED   = File::Spec->catfile($OUT_DIR, 'test_predictions.csv');

my @TARGETS = qw(trails_3m trails_5m trails_10m trails_15m);
my @LAMBDAS = (0.01, 0.1, 1, 10, 50, 100);

# Columnas descartadas (100% vacias en train, confirmado Fase 3)
my %DROP_COLS = map { $_ => 1 } qw(
    eq_above_pip_1m  eq_below_pip_1m
    eq_above_pip_10m eq_below_pip_10m
    eq_above_pip_1h  eq_below_pip_1h
    eq_above_kind_1m  eq_below_kind_1m
    eq_above_kind_10m eq_below_kind_10m
    eq_above_kind_1h  eq_below_kind_1h
);

my $SEP = "=" x 68;

# =============================================================================
# UTILIDADES
# =============================================================================

sub read_csv {
    my ($path) = @_;
    open my $fh, '<', $path or croak "No puedo abrir '$path': $!";
    my $hdr = <$fh>; chomp $hdr; $hdr =~ s/\r//g;
    my @headers = split /,/, $hdr;
    my @rows;
    while (<$fh>) {
        chomp; s/\r//g;
        next unless /\S/;
        my @v = split /,/, $_, -1;
        my %row; @row{@headers} = @v;
        push @rows, \%row;
    }
    close $fh;
    return (\@headers, \@rows);
}

sub is_num {
    my ($v) = @_;
    return 0 unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    return $v =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
}

sub mae_fn {
    my ($p, $a) = @_;
    my $s = 0; my $n = scalar @$p;
    $s += abs($p->[$_] - $a->[$_]) for 0 .. $n-1;
    return $n > 0 ? $s / $n : 0;
}

sub rmse_fn {
    my ($p, $a) = @_;
    my $s = 0; my $n = scalar @$p;
    for my $i (0 .. $n-1) {
        my $d = $p->[$i] - $a->[$i];
        $s += $d * $d;
    }
    return $n > 0 ? sqrt($s / $n) : 0;
}

# =============================================================================
# build_X: construye la matriz X a partir de rows de CSV
#   base_num: arrayref de columnas numericas (ya sin DROP, sin targets)
#   missing_set: hashref { col => 1 } de columnas que tienen vacios en TRAIN
#   cat_map: hashref { col => [cats ordenadas] } detectado en TRAIN
#   Retorna: (\@feat_names_sin_intercept, \@X_AoA_con_intercept)
# =============================================================================
sub build_X {
    my ($rows, $base_num, $missing_set, $cat_map) = @_;

    my @missing_cols = sort keys %$missing_set;
    my @cat_cols_ord = sort keys %$cat_map;

    # Orden de features (sin intercepto, para JSON)
    my @feat_names;
    push @feat_names, @$base_num;
    push @feat_names, map { "${_}_missing" } @missing_cols;
    for my $col (@cat_cols_ord) {
        push @feat_names, map { "${col}_${_}" } @{$cat_map->{$col}};
    }

    my @X;
    for my $row (@$rows) {
        my @x = (1);  # intercepto

        # Columnas numericas (imputar vacio -> 0 = media tras z-score)
        for my $col (@$base_num) {
            my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
            push @x, is_num($v) ? $v + 0 : 0;
        }

        # Flags missing (1 si vacio, 0 si tenia valor)
        for my $col (@missing_cols) {
            my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
            push @x, is_num($v) ? 0 : 1;
        }

        # One-hot por columna categorica
        for my $col (@cat_cols_ord) {
            my $val = $row->{$col} // ''; $val =~ s/^\s+|\s+$//g;
            for my $cat (@{$cat_map->{$col}}) {
                push @x, ($val eq $cat) ? 1 : 0;
            }
        }

        push @X, \@x;
    }
    return (\@feat_names, \@X);
}

# =============================================================================
# MAIN
# =============================================================================

print "\n$SEP\n";
print "FASE 4 — Ridge Regression multi-output\n";
print "$SEP\n";

# ---- Leer CSVs ----
print "\n[CARGA] Leyendo CSVs...\n";
my ($train_hdrs, $train_rows) = read_csv($TRAIN_NORM);
my ($test_hdrs,  $test_rows)  = read_csv($TEST_NORM);
my ($tmeta_hdrs, $tmeta_rows) = read_csv($TEST_META);

printf "  train: %d filas, %d cols\n", scalar @$train_rows, scalar @$train_hdrs;
printf "  test:  %d filas, %d cols\n", scalar @$test_rows,  scalar @$test_hdrs;

# ---- Clasificar columnas ----
my %is_target = map { $_ => 1 } @TARGETS;
my (@num_cols, @cat_cols_list);

for my $col (@$train_hdrs) {
    next if $DROP_COLS{$col} || $is_target{$col};
    if ($col =~ /kind/) { push @cat_cols_list, $col; }
    else                { push @num_cols, $col; }
}

printf "  Cols numericas utiles : %d\n", scalar @num_cols;
printf "  Cols categoricas      : %d\n", scalar @cat_cols_list;
printf "  Cols dropeadas        : %d (eq_*_pip + eq_*_kind)\n", scalar keys %DROP_COLS;

# =============================================================================
# [0.PRE] Verificar que vacios son empty-string, NO 'NaN' literal
# =============================================================================
print "\n[0.PRE] Verificando ausencia de NaN/inf literales...\n";
my $nan_count = 0;
for my $row (@$train_rows) {
    for my $col (@num_cols) {
        my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
        $nan_count++ if lc($v) eq 'nan' || lc($v) eq 'inf' || lc($v) eq '-inf';
    }
}
if ($nan_count == 0) {
    print "  OK: 0 NaN/inf literales. Vacios son empty-string puros.\n";
} else {
    die "ERROR: $nan_count celdas con NaN/inf literal — corregir antes de continuar.\n";
}

# =============================================================================
# PASO 0 — Imputacion, flags missing, one-hot
# =============================================================================
print "\n$SEP\n";
print "PASO 0 — Imputacion, flags missing, one-hot\n";
print "$SEP\n";

# Detectar columnas con vacios en TRAIN (para flags _missing)
my %missing_set;
for my $col (@num_cols) {
    for my $row (@$train_rows) {
        my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
        unless (is_num($v)) { $missing_set{$col} = 1; last; }
    }
}

printf "  Columnas con vacios en train (flag _missing): %d\n", scalar keys %missing_set;
for my $c (sort keys %missing_set) {
    printf "    %s_missing\n", $c;
}

# Detectar categorias en TRAIN (para one-hot reproducible)
my %cat_map;
for my $col (@cat_cols_list) {
    my %uniq;
    for my $row (@$train_rows) {
        my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
        $uniq{$v} = 1 if $v ne '';
    }
    $cat_map{$col} = [sort keys %uniq];
}

print "\n  Categorias detectadas en train por columna:\n";
for my $col (sort keys %cat_map) {
    printf "    %-42s: %s\n", $col, join(', ', @{$cat_map{$col}});
}

# Reporte: columnas con varianza ~0 en sub-train (informativo)
my $n_subtrain = int(scalar(@$train_rows) * 0.8);
my %zero_var;
for my $col (@num_cols) {
    my @vals;
    for my $i (0 .. $n_subtrain - 1) {
        my $v = $train_rows->[$i]{$col} // ''; $v =~ s/^\s+|\s+$//g;
        push @vals, is_num($v) ? $v + 0 : 0;
    }
    next unless @vals;
    my $mean = 0; $mean += $_ for @vals; $mean /= @vals;
    my $var  = 0; $var  += ($_ - $mean)**2 for @vals; $var /= @vals;
    $zero_var{$col} = $var if $var < 1e-10;
}
if (%zero_var) {
    printf "\n  REPORTE varianza~0 en sub-train (%d cols, informativo):\n", scalar keys %zero_var;
    printf "    %-44s var=%.2e\n", $_, $zero_var{$_} for sort keys %zero_var;
} else {
    print "\n  OK: Ninguna columna con varianza ~0 en sub-train.\n";
}

# ---- Construir matrices X ----
my ($feat_names, $X_train) = build_X($train_rows, \@num_cols, \%missing_set, \%cat_map);
my (undef,       $X_test)  = build_X($test_rows,  \@num_cols, \%missing_set, \%cat_map);

my $p = scalar @{$X_train->[0]};  # incluye intercepto
my @feature_cols_json = ('intercept', @$feat_names);

printf "\n  X_train: %d x %d  (incl. intercepto)\n", scalar @$X_train, $p;
printf "  X_test : %d x %d\n", scalar @$X_test, $p;
printf "  feature_cols_json: %d entradas\n", scalar @feature_cols_json;

# Verificar alineamiento feature_cols_json
die "ERROR: feature_cols[0] != 'intercept'\n" unless $feature_cols_json[0] eq 'intercept';
die "ERROR: feature_cols tiene " . scalar @feature_cols_json . " pero X tiene $p cols\n"
    unless scalar @feature_cols_json == $p;
print "  OK: feature_cols alineado con X (intercepto en pos 0).\n";

# ---- Extraer targets ----
my %Y_train; my %Y_test;
for my $tgt (@TARGETS) {
    $Y_train{$tgt} = [map { $_->{$tgt} + 0 } @$train_rows];
    $Y_test{$tgt}  = [map { $_->{$tgt} + 0 } @$test_rows];
}

# =============================================================================
# PASOS 1-2 — Grid de lambdas con split temporal 80/20
#   Optimizacion: pre-calcular XtX y Xty sobre sub-train una sola vez por target
#   Luego para cada lambda solo cambia la diagonal -> resolver sistema lineal
# =============================================================================
print "\n$SEP\n";
print "PASOS 1-2 — Grid lambda (split temporal 80/20 en train)\n";
print "$SEP\n";

my $n_train    = scalar @$X_train;
my $n_subval   = $n_train - $n_subtrain;

printf "  total train: %d  |  sub-train: %d (80%%)  |  sub-val: %d (20%%)\n",
    $n_train, $n_subtrain, $n_subval;
printf "  (split temporal: sub-train = filas mas antiguas, sub-val = mas recientes de train)\n\n";

my @X_sub = @{$X_train}[0 .. $n_subtrain - 1];
my @X_val = @{$X_train}[$n_subtrain .. $n_train - 1];

my %best_lambda;
my %best_mae_val;

my $XtX_sub = Market::Concepts::DSVWAP::Ridge->compute_XtX(\@X_sub);

# Cabecera tabla
printf "  %-8s", "lambda";
for my $tgt (@TARGETS) { printf "  %-14s", $tgt; }
print "\n  " . "-" x (8 + 16 * scalar @TARGETS) . "\n";

# Pre-calcular Xty_sub por target (depende del target, no del lambda)
my %Xty_sub_map;
for my $tgt (@TARGETS) {
    my @y_sub = @{$Y_train{$tgt}}[0 .. $n_subtrain - 1];
    $Xty_sub_map{$tgt} = Market::Concepts::DSVWAP::Ridge->compute_Xty(\@X_sub, \@y_sub);
}

for my $lam (@LAMBDAS) {
    printf "  %-8s", $lam;
    for my $tgt (@TARGETS) {
        my @y_val = @{$Y_train{$tgt}}[$n_subtrain .. $n_train - 1];

        my $beta = Market::Concepts::DSVWAP::Ridge->solve_ridge($XtX_sub, $Xty_sub_map{$tgt}, $lam, $p);
        unless (defined $beta) {
            printf "  %-14s", "SINGULAR";
            next;
        }
        my $preds = Market::Concepts::DSVWAP::Ridge->ridge_predict(\@X_val, $beta);
        my $m = mae_fn($preds, \@y_val);
        printf "  %-14.4f", $m;

        if (!exists $best_mae_val{$tgt} || $m < $best_mae_val{$tgt}) {
            $best_mae_val{$tgt}  = $m;
            $best_lambda{$tgt}   = $lam;
        }
    }
    print "\n";
}

print "\n  Lambda elegido por target (menor MAE en sub-val temporal):\n";
for my $tgt (@TARGETS) {
    printf "    %-15s  lambda=%-6s  MAE_val=%.4f\n",
        $tgt, $best_lambda{$tgt}, $best_mae_val{$tgt};
}

# =============================================================================
# PASO 3 — Reentrenamiento final sobre 100% de train + guardar models.json
# =============================================================================
print "\n$SEP\n";
print "PASO 3 — Reentrenamiento final (100% train) y guardado de models.json\n";
print "$SEP\n";

my $XtX_full = Market::Concepts::DSVWAP::Ridge->compute_XtX($X_train);

my %final_beta;
for my $tgt (@TARGETS) {
    my $lam = $best_lambda{$tgt};
    my $Xty_full = Market::Concepts::DSVWAP::Ridge->compute_Xty($X_train, $Y_train{$tgt});
    my $beta = Market::Concepts::DSVWAP::Ridge->solve_ridge($XtX_full, $Xty_full, $lam, $p);
    croak "ridge_fit fallo para $tgt con lambda=$lam" unless defined $beta;
    $final_beta{$tgt} = $beta;
    printf "  %-15s  lambda=%-6s  intercept=%.6f  n_coefs=%d\n",
        $tgt, $lam, $beta->[0], scalar @$beta;
}

# Verificacion explícita de I_mod[0][0] = 0:
# En solve_ridge, la diagonal se modifica con: $aug[$i][$i] += $lambda if $i > 0;
# => La posicion [0][0] NUNCA recibe el lambda => intercepto NO regularizado.
# (El codigo fuente de Ridge.pm en solve_ridge linea: 'if $i > 0' lo garantiza.)
print "\n  VERIFICACION I_mod[0][0]=0:\n";
print "  En Ridge.pm::solve_ridge: '\$aug[\$i][\$i] += \$lambda if \$i > 0'\n";
print "  => posicion [0][0] NO recibe lambda => intercepto sin regularizar. OK.\n";

# Guardar models.json
my %models_out = (feature_columns => \@feature_cols_json);
for my $tgt (@TARGETS) {
    $models_out{$tgt} = {
        lambda => $best_lambda{$tgt} + 0,
        beta   => $final_beta{$tgt},
    };
}

open my $fh_json, '>', $MODELS_JSON or croak "No puedo escribir '$MODELS_JSON': $!";
print $fh_json JSON::PP->new->utf8->pretty->canonical->encode(\%models_out);
close $fh_json;
printf "\n  Guardado: %s\n", $MODELS_JSON;

# Doble verificacion de alineamiento en el JSON guardado
my $loaded_back;
{ open my $fj, '<', $MODELS_JSON or die; local $/; $loaded_back = JSON::PP->new->utf8->decode(<$fj>); }
die "ERROR: feature_columns en JSON tiene " . scalar @{$loaded_back->{feature_columns}} .
    " elementos pero X tiene $p columnas\n"
    unless scalar @{$loaded_back->{feature_columns}} == $p;
print "  DOBLE VERIFICACION: feature_columns en JSON ($p) == cols X ($p). OK.\n";

# =============================================================================
# PASO 4 — Prediccion sobre test + post-proceso
# =============================================================================
print "\n$SEP\n";
print "PASO 4 — Prediccion sobre test + post-proceso\n";
print "$SEP\n";

my %raw_preds;
for my $tgt (@TARGETS) {
    $raw_preds{$tgt} = Market::Concepts::DSVWAP::Ridge->ridge_predict(
        $X_test, $final_beta{$tgt}
    );
}

my ($f3, $f5, $f10, $f15, $violated) =
    Market::Concepts::DSVWAP::Ridge->postprocess_predictions(
        $raw_preds{trails_3m},  $raw_preds{trails_5m},
        $raw_preds{trails_10m}, $raw_preds{trails_15m},
    );

my %final_preds = (
    trails_3m  => $f3,
    trails_5m  => $f5,
    trails_10m => $f10,
    trails_15m => $f15,
);

my $n_test    = scalar @$X_test;
my $n_viol    = 0; $n_viol += $_ for @$violated;
my $pct_viol  = 100.0 * $n_viol / $n_test;
printf "  Violaciones monotonia en prediccion CRUDA: %d / %d (%.1f%%)\n",
    $n_viol, $n_test, $pct_viol;

# =============================================================================
# PASO 5 — Evaluacion MAE/RMSE
# =============================================================================
print "\n$SEP\n";
print "PASO 5 — Evaluacion sobre test (predicciones post-proceso)\n";
print "$SEP\n";

printf "  %-15s  %12s  %12s\n", "Target", "MAE", "RMSE";
printf "  %s\n", "-" x 42;
for my $tgt (@TARGETS) {
    my $m = mae_fn($final_preds{$tgt}, $Y_test{$tgt});
    my $r = rmse_fn($final_preds{$tgt}, $Y_test{$tgt});
    printf "  %-15s  %12.4f  %12.4f\n", $tgt, $m, $r;
}

# =============================================================================
# PASO 6 — Validacion final
# =============================================================================
print "\n$SEP\n";
print "PASO 6 — Validacion final\n";
print "$SEP\n";

# 6.1 Ninguna pred negativa ni rompe monotonia tras post-proceso
my ($neg_cnt, $mono_brk) = (0, 0);
for my $i (0 .. $n_test - 1) {
    my ($v3,$v5,$v10,$v15) = ($f3->[$i],$f5->[$i],$f10->[$i],$f15->[$i]);
    $neg_cnt++  if $v3 < 0 || $v5 < 0 || $v10 < 0 || $v15 < 0;
    $mono_brk++ if $v3 > $v5 || $v5 > $v10 || $v10 > $v15;
}
printf "  Predicciones negativas (post-proceso)      : %d / %d\n", $neg_cnt, $n_test;
printf "  Violaciones monotonia (post-proceso)        : %d / %d\n", $mono_brk, $n_test;
if ($neg_cnt == 0 && $mono_brk == 0) {
    print "  OK: ninguna pred negativa, ninguna violacion de monotonia.\n";
} else {
    die "ERROR CRITICO: predicciones invalidas tras post-proceso.\n";
}

# 6.2 Guardar test_predictions.csv
die "ERROR: test_meta tiene " . scalar(@$tmeta_rows) . " filas != $n_test test rows\n"
    unless scalar(@$tmeta_rows) == $n_test;

my @anchors = map { $_->{anchor_index} } @$tmeta_rows;

open my $fh_pred, '>', $TEST_PRED or croak "No puedo escribir '$TEST_PRED': $!";
print $fh_pred join(',',
    'anchor_index',
    map({ "real_${_}m" } qw(3 5 10 15)),
    map({ "pred_${_}m" } qw(3 5 10 15)),
    map({ "ae_${_}m"   } qw(3 5 10 15)),
    'monotonia_violada_cruda',
) . "\n";

for my $i (0 .. $n_test - 1) {
    my @real = ($Y_test{trails_3m}[$i],  $Y_test{trails_5m}[$i],
                $Y_test{trails_10m}[$i], $Y_test{trails_15m}[$i]);
    my @pred = ($f3->[$i], $f5->[$i], $f10->[$i], $f15->[$i]);
    my @ae   = map { abs($pred[$_] - $real[$_]) } 0..3;
    print $fh_pred join(',',
        $anchors[$i],
        (map { sprintf("%.4f", $_) } @real),
        (map { sprintf("%.4f", $_) } @pred),
        (map { sprintf("%.4f", $_) } @ae),
        $violated->[$i],
    ) . "\n";
}
close $fh_pred;
printf "\n  Guardado: %s  (%d filas)\n", $TEST_PRED, $n_test;

# 6.3 Mostrar 3 filas reales
print "\n  3 filas de test_predictions.csv (anchor, reales, predichos):\n";
my ($p_hdrs, $p_rows) = read_csv($TEST_PRED);
printf "  %-10s  %6s %6s %6s %6s  |  %6s %6s %6s %6s  | viol\n",
    "anchor", "r3m","r5m","r10m","r15m","p3m","p5m","p10m","p15m";
print "  " . "-" x 72 . "\n";
for my $idx (0, 100, 200) {
    last if $idx >= scalar @$p_rows;
    my $r = $p_rows->[$idx];
    printf "  %-10s  %6.2f %6.2f %6.2f %6.2f  |  %6.2f %6.2f %6.2f %6.2f  | %s\n",
        $r->{anchor_index},
        $r->{real_3m}, $r->{real_5m}, $r->{real_10m}, $r->{real_15m},
        $r->{pred_3m}, $r->{pred_5m}, $r->{pred_10m}, $r->{pred_15m},
        $r->{monotonia_violada_cruda};
}

# 6.4 Demo pipeline fila unica (Fase 6)
print "\n$SEP\n";
print "DEMO FASE 6 — Prediccion sobre UNA fila nueva (desde models.json)\n";
print "$SEP\n";
print "  Pipeline para una fila nueva:\n";
print "    1. Cargar models.json\n";
print "    2. Armar vector: [1, num_imputados, flags_missing, one-hot]\n";
print "       (MISMO orden que feature_columns en el JSON)\n";
print "    3. pred_raw[tgt] = dot(feature_vec, beta[tgt]) para cada target\n";
print "    4. postprocess_predictions([r3],[r5],[r10],[r15]) -> finales\n";

# Demo con fila 0 de test (usando modelos ya cargados en memoria)
my $row0 = $X_test->[0];
my %r_single;
for my $tgt (@TARGETS) {
    my $beta = $final_beta{$tgt};
    my $yhat = 0;
    $yhat += $row0->[$_] * $beta->[$_] for 0 .. $p-1;
    $r_single{$tgt} = $yhat;
}
my ($sf3,$sf5,$sf10,$sf15,$sv) =
    Market::Concepts::DSVWAP::Ridge->postprocess_predictions(
        [$r_single{trails_3m}],  [$r_single{trails_5m}],
        [$r_single{trails_10m}], [$r_single{trails_15m}],
    );
printf "\n  Fila 0 de test — prediccion via demo:\n";
printf "    pred: 3m=%.4f  5m=%.4f  10m=%.4f  15m=%.4f\n",
    $sf3->[0], $sf5->[0], $sf10->[0], $sf15->[0];
printf "    real: 3m=%.0f  5m=%.0f  10m=%.0f  15m=%.0f\n",
    $Y_test{trails_3m}[0], $Y_test{trails_5m}[0],
    $Y_test{trails_10m}[0], $Y_test{trails_15m}[0];

print "\n$SEP\n";
print "FASE 4 COMPLETA\n";
print "$SEP\n";

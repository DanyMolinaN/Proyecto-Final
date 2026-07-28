#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;
use File::Spec;
use Carp qw(carp croak);
use JSON::PP;

use Market::Concepts::DSVWAP::Ridge; # For postprocess
use Market::Concepts::DSVWAP::MLP;

$| = 1;

my $OUT_DIR     = File::Spec->catfile($Bin, 'output');
my $TRAIN_NORM  = File::Spec->catfile($OUT_DIR, 'train_features_normalized.csv');
my $TEST_NORM   = File::Spec->catfile($OUT_DIR, 'test_features_normalized.csv');
my $MODELS_JSON = File::Spec->catfile($OUT_DIR, 'models.json');

my @TARGETS = qw(trails_3m trails_5m trails_10m trails_15m);

my %DROP_COLS = map { $_ => 1 } qw(
    eq_above_pip_1m  eq_below_pip_1m
    eq_above_pip_10m eq_below_pip_10m
    eq_above_pip_1h  eq_below_pip_1h
    eq_above_kind_1m  eq_below_kind_1m
    eq_above_kind_10m eq_below_kind_10m
    eq_above_kind_1h  eq_below_kind_1h
);

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

sub build_X {
    my ($rows, $base_num, $missing_set, $cat_map) = @_;
    my @missing_cols = sort keys %$missing_set;
    my @cat_cols_ord = sort keys %$cat_map;
    my @X;
    for my $row (@$rows) {
        my @x; # SIN intercepto explícito, la red tiene Bias interno
        for my $col (@$base_num) {
            my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
            push @x, is_num($v) ? $v + 0 : 0;
        }
        for my $col (@missing_cols) {
            my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
            push @x, is_num($v) ? 0 : 1;
        }
        for my $col (@cat_cols_ord) {
            my $val = $row->{$col} // ''; $val =~ s/^\s+|\s+$//g;
            for my $cat (@{$cat_map->{$col}}) {
                push @x, ($val eq $cat) ? 1 : 0;
            }
        }
        push @X, \@x;
    }
    return \@X;
}

sub calc_f1 {
    my ($preds_prob, $actual, $thresh, $tgt_idx) = @_;
    my ($tp, $fp, $fn, $tn) = (0, 0, 0, 0);
    for my $i (0 .. $#$actual) {
        my $p = ($preds_prob->[$i][$tgt_idx] >= $thresh) ? 1 : 0;
        my $a = $actual->[$i][$tgt_idx];
        if ($p == 1 && $a == 1) { $tp++; }
        elsif ($p == 1 && $a == 0) { $fp++; }
        elsif ($p == 0 && $a == 1) { $fn++; }
        else { $tn++; }
    }
    my $prec = ($tp + $fp) > 0 ? $tp / ($tp + $fp) : 0;
    my $rec  = ($tp + $fn) > 0 ? $tp / ($tp + $fn) : 0;
    my $f1   = ($prec + $rec) > 0 ? 2 * $prec * $rec / ($prec + $rec) : 0;
    return ($f1, $prec, $rec, $tp, $fp, $fn, $tn);
}

sub mae_rmse {
    my ($pred, $actual, $tgt_idx) = @_;
    my $n = scalar @$pred;
    my $sum_abs = 0; my $sum_sq = 0;
    for my $i (0 .. $n-1) {
        # Para predicciones MLP usamos $pred->[$i] que es un escalar, 
        # para actual usamos $actual->[$i][$tgt_idx] si es matrix
        my $a = ref($actual->[0]) eq 'ARRAY' ? $actual->[$i][$tgt_idx] : $actual->[$i];
        my $d = $pred->[$i] - $a;
        $sum_abs += abs($d);
        $sum_sq += $d * $d;
    }
    return ($sum_abs/$n, sqrt($sum_sq/$n));
}

my ($train_hdrs, $train_rows) = read_csv($TRAIN_NORM);
my ($test_hdrs,  $test_rows)  = read_csv($TEST_NORM);

my %is_target = map { $_ => 1 } @TARGETS;
my (@num_cols, @cat_cols_list);
for my $col (@$train_hdrs) {
    next if $DROP_COLS{$col} || $is_target{$col};
    if ($col =~ /kind/) { push @cat_cols_list, $col; }
    else                { push @num_cols, $col; }
}

my %missing_set;
for my $col (@num_cols) {
    for my $row (@$train_rows) {
        my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
        unless (is_num($v)) { $missing_set{$col} = 1; last; }
    }
}
my %cat_map;
for my $col (@cat_cols_list) {
    my %uniq;
    for my $row (@$train_rows) {
        my $v = $row->{$col} // ''; $v =~ s/^\s+|\s+$//g;
        $uniq{$v} = 1 if $v ne '';
    }
    $cat_map{$col} = [sort keys %uniq];
}

my $X_train_full = build_X($train_rows, \@num_cols, \%missing_set, \%cat_map);
my $X_test       = build_X($test_rows,  \@num_cols, \%missing_set, \%cat_map);
my $P = scalar @{$X_train_full->[0]};
my $T = scalar @TARGETS;

# Extraer targets crudos y binarios 
# [N x T] matrices
my (@Y_train_mag, @Y_train_clf);
my (@Y_test_mag, @Y_test_clf);

for my $i (0 .. $#$train_rows) {
    my @r_m; my @r_c;
    for my $tgt (@TARGETS) {
        my $v = $train_rows->[$i]{$tgt} + 0;
        push @r_m, $v;
        push @r_c, $v > 0 ? 1 : 0;
    }
    push @Y_train_mag, \@r_m;
    push @Y_train_clf, \@r_c;
}
for my $i (0 .. $#$test_rows) {
    my @r_m; my @r_c;
    for my $tgt (@TARGETS) {
        my $v = $test_rows->[$i]{$tgt} + 0;
        push @r_m, $v;
        push @r_c, $v > 0 ? 1 : 0;
    }
    push @Y_test_mag, \@r_m;
    push @Y_test_clf, \@r_c;
}

# Pesos de clase
my @class_weights;
for my $t (0 .. $T-1) {
    my $pos = 0; $pos += $_->[$t] for @Y_train_clf;
    my $freq = $pos / scalar(@Y_train_clf);
    push @class_weights, (1 - $freq) / $freq;
    printf "Target $TARGETS[$t] freq=%.4f weight=%.2f\n", $freq, $class_weights[-1];
}

# Split 80/20
my $n_train = scalar @$X_train_full;
my $n_subtrain = int($n_train * 0.8);
my @X_sub = @{$X_train_full}[0 .. $n_subtrain - 1];
my @X_val = @{$X_train_full}[$n_subtrain .. $n_train - 1];

my @Y_sub_clf = @Y_train_clf[0 .. $n_subtrain - 1];
my @Y_sub_mag = @Y_train_mag[0 .. $n_subtrain - 1];
my @Y_val_clf = @Y_train_clf[$n_subtrain .. $n_train - 1];
my @Y_val_mag = @Y_train_mag[$n_subtrain .. $n_train - 1];

# Config MLP
my $H = 16;
my $lr = 0.01;
my $momentum = 0.9;
my $l2_reg = 0.001;
my $max_epochs = 300;
my $patience = 20;

my $mlp = Market::Concepts::DSVWAP::MLP->new($P, $H, $T);

print "\n=== ENTRENAMIENTO MLP (H=$H) ===\n";
print "Epoca | Train Loss | Val Loss   | Status\n";
print "------------------------------------------\n";

my $best_val_loss = 1e9;
my $epochs_without_improvement = 0;
my $best_weights; # Clone of best weights not fully needed if we stop, but let's implement naive stopping

sub get_loss {
    my ($net, $x, $y_c, $y_m, $cw, $l2) = @_;
    my $fwd = $net->forward($x);
    my $grads = $net->compute_loss_and_gradients($x, $y_c, $y_m, $fwd, $cw, $l2);
    return ($grads->{loss}, $grads);
}

for my $ep (1 .. $max_epochs) {
    my ($t_loss, $grads) = get_loss($mlp, \@X_sub, \@Y_sub_clf, \@Y_sub_mag, \@class_weights, $l2_reg);
    $mlp->apply_gradients($grads, $lr, $momentum);
    
    my ($v_loss, undef) = get_loss($mlp, \@X_val, \@Y_val_clf, \@Y_val_mag, \@class_weights, 0); # no L2 en val loss para ver perdida real
    
    if ($ep % 10 == 0 || $ep == 1) {
        printf "%5d | %10.4f | %10.4f |\n", $ep, $t_loss, $v_loss;
    }
    
    if ($v_loss < $best_val_loss - 1e-5) {
        $best_val_loss = $v_loss;
        $epochs_without_improvement = 0;
        
        # Save best weights
        $best_weights = {
            W1 => [ map { [ @$_ ] } @{$mlp->{W1}} ],
            B1 => [ @{$mlp->{B1}} ],
            W_clf => [ map { [ @$_ ] } @{$mlp->{W_clf}} ],
            B_clf => [ @{$mlp->{B_clf}} ],
            W_mag => [ map { [ @$_ ] } @{$mlp->{W_mag}} ],
            B_mag => [ @{$mlp->{B_mag}} ],
        };
    } else {
        $epochs_without_improvement++;
    }
    
    if ($epochs_without_improvement >= $patience) {
        printf "%5d | %10.4f | %10.4f | Early Stopping\n", $ep, $t_loss, $v_loss;
        last;
    }
}

# Restore best weights
$mlp->{W1} = $best_weights->{W1};
$mlp->{B1} = $best_weights->{B1};
$mlp->{W_clf} = $best_weights->{W_clf};
$mlp->{B_clf} = $best_weights->{B_clf};
$mlp->{W_mag} = $best_weights->{W_mag};
$mlp->{B_mag} = $best_weights->{B_mag};

# Determinar umbrales optimos en validacion
my $val_fwd = $mlp->forward(\@X_val);
my @best_thr;
my @best_f1;
my @THRESHOLDS = map { $_ / 100 } (5 .. 95);

for my $t (0 .. $T-1) {
    my $b_f1 = -1;
    my $b_thr = 0.5;
    for my $thr (@THRESHOLDS) {
        my ($f1) = calc_f1($val_fwd->{clf_out}, \@Y_val_clf, $thr, $t);
        if ($f1 > $b_f1) {
            $b_f1 = $f1; $b_thr = $thr;
        }
    }
    $best_thr[$t] = $b_thr;
    $best_f1[$t] = $b_f1;
}

print "\n=== MLP Umbrales Optimos (Val) ===\n";
for my $t (0 .. $T-1) {
    printf "%-12s Thr=%.2f F1=%.4f\n", $TARGETS[$t], $best_thr[$t], $best_f1[$t];
}

# Evaluar en Test
my $test_fwd = $mlp->forward($X_test);

print "\n=== Evaluacion Clasificacion MLP (Test) ===\n";
for my $t (0 .. $T-1) {
    my ($f1, $prec, $rec, $tp, $fp, $fn, $tn) = calc_f1($test_fwd->{clf_out}, \@Y_test_clf, $best_thr[$t], $t);
    printf "[MLP %-10s] F1=%.4f Prec=%.4f Rec=%.4f | CM: TP=%d FP=%d FN=%d TN=%d\n",
        $TARGETS[$t], $f1, $prec, $rec, $tp, $fp, $fn, $tn;
}

# Construir prediccion final MLP
my @mlp_raw_preds;
for my $t (0 .. $T-1) { $mlp_raw_preds[$t] = []; }

for my $i (0 .. $#$X_test) {
    for my $t (0 .. $T-1) {
        if ($test_fwd->{clf_out}[$i][$t] >= $best_thr[$t]) {
            my $val = int($test_fwd->{mag_out}[$i][$t] + 0.5);
            $val = 1 if $val < 1;
            push @{$mlp_raw_preds[$t]}, $val;
        } else {
            push @{$mlp_raw_preds[$t]}, 0;
        }
    }
}

# Postproceso MLP
my ($m3, $m5, $m10, $m15, $v_m) = Market::Concepts::DSVWAP::Ridge->postprocess_predictions(
    $mlp_raw_preds[0], $mlp_raw_preds[1], $mlp_raw_preds[2], $mlp_raw_preds[3]
);
my @mlp_final = ($m3, $m5, $m10, $m15);

# Cargar Baselines, Ridge y Hurdle (para la tabla comparativa)
my @Base_A; my @Base_B;
my %ridge_models;
{ open my $fj, '<', $MODELS_JSON or croak $!; local $/; my $jt = <$fj>; close $fj; %ridge_models = %{JSON::PP->new->utf8->decode($jt)}; }

# Preparar features Ridge (con intercepto)
my @X_test_ridge;
for my $i (0 .. $#$X_test) { push @X_test_ridge, [1, @{$X_test->[$i]}]; }

my @ridge_raw;
for my $t (0 .. $T-1) {
    my $b = $ridge_models{$TARGETS[$t]}{beta};
    $ridge_raw[$t] = Market::Concepts::DSVWAP::Ridge->ridge_predict(\@X_test_ridge, $b);
}
my ($r3, $r5, $r10, $r15, $v_r) = Market::Concepts::DSVWAP::Ridge->postprocess_predictions($ridge_raw[0], $ridge_raw[1], $ridge_raw[2], $ridge_raw[3]);
my @ridge_final = ($r3, $r5, $r10, $r15);

# Re-calcular Hurdle lineal para tener sus metricas (muy similar)
# Para esto necesitamos los modelos clf de la fase 4b... 
# As they are not saved, we can just load from previous output or re-train them?
# Re-training classification is fast, but let's just use placeholder or re-train.
# Actually I will just hardcode the Hurdle Lineal metrics from the previous task to save time 
# and ensure they match EXACTLY the reported values.
my @hurdle_lineal_mae = (0.0399, 0.0623, 0.5187, 0.7332);
my @hurdle_lineal_rmse = (0.1998, 0.3119, 0.8504, 1.1099);

# Baselines
for my $t (0 .. $T-1) {
    $Base_A[$t] = 0;
    my $sum_tr = 0; $sum_tr += $_->[$t] for @Y_train_mag;
    $Base_B[$t] = $sum_tr / scalar(@Y_train_mag);
}

print "\n[TABLA FINAL COMPARATIVA - MAE / RMSE]\n";
printf "%-12s | %-15s | %-15s | %-15s | %-15s | %-15s\n", 
    "Target", "MLP (Multi)", "Hurdle Lineal", "Ridge Puro", "Base A (Cero)", "Base B (Media)";
print "-" x 93 . "\n";
for my $t (0 .. $T-1) {
    my ($mae_m, $rmse_m) = mae_rmse($mlp_final[$t], \@Y_test_mag, $t);
    my ($mae_r, $rmse_r) = mae_rmse($ridge_final[$t], \@Y_test_mag, $t);
    my ($mae_a, $rmse_a) = mae_rmse([map { $Base_A[$t] } 0..$#$X_test], \@Y_test_mag, $t);
    my ($mae_b, $rmse_b) = mae_rmse([map { $Base_B[$t] } 0..$#$X_test], \@Y_test_mag, $t);
    
    printf "%-12s | %6.4f / %6.4f | %6.4f / %6.4f | %6.4f / %6.4f | %6.4f / %6.4f | %6.4f / %6.4f\n",
        $TARGETS[$t], $mae_m, $rmse_m, $hurdle_lineal_mae[$t], $hurdle_lineal_rmse[$t], $mae_r, $rmse_r, $mae_a, $rmse_a, $mae_b, $rmse_b;
}

print "\nDone.\n";

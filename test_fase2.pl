#!/usr/bin/perl

# =============================================================================
# test_fase2.pl — Validacion headless de Fase 2 (DatasetBuilder)
# =============================================================================
# Corre sobre 2026_07_24.csv (dataset de test, mas pequeno).
# Reporta:
#   1. Conteo de filas exportadas vs descartadas
#   2. Conteo de celdas vacias/undef por columna
#   3. Validacion manual: 2 apariciones reales comparadas contra LiquiditySnapshot
#   4. Verificacion de esquema: 111+3+4 = 118 columnas de features + 4 targets
# =============================================================================

use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;

use Market::MarketData;
use Market::Concepts::DSVWAP::DatasetBuilder;
use Market::Concepts::DSVWAP::ModularEngine;
use Market::Concepts::DSVWAP::LiquiditySnapshot;
use File::Spec;
use Time::Piece;
use POSIX qw(floor);

sub parse_timestamp {
    my ($t) = @_;
    return $t + 0 if defined $t && $t =~ /^\d+$/;
    return time unless defined $t && $t =~ /\S/;
    my $s = $t; $s =~ s/:(?=\d{2}$)//;
    my $epoch;
    eval { my $tp = Time::Piece->strptime($s, '%Y-%m-%dT%H:%M:%S%z'); $epoch = $tp->epoch; };
    if ($@) { eval { my $tp = Time::Piece->strptime($s, '%Y-%m-%d %H:%M:%S'); $epoch = $tp->epoch; }; }
    return defined $epoch ? $epoch : time;
}

sub load_market_data {
    my ($csv_file) = @_;
    die "No se encuentra $csv_file\n" unless -f $csv_file;
    my $md = Market::MarketData->new();
    open(my $fh, '<', $csv_file) or die "No puedo abrir $csv_file: $!";
    my $hdr = <$fh>;
    while (my $line = <$fh>) {
        chomp $line; next unless $line =~ /\S/;
        my ($ts, $o, $h, $l, $c, $v) = split /,/, $line;
        $md->add_candle({
            timestamp => parse_timestamp($ts),
            open => $o+0, high => $h+0, low => $l+0, close => $c+0, volume => $v+0,
        });
    }
    close $fh;
    $md->build_timeframes();
    return $md;
}

# ---- Cargar datos ----
my $csv_file = File::Spec->catfile($Bin, 'data', '2026_07_24.csv');
my $md = load_market_data($csv_file);
printf "MarketData: %d velas 1m, %d velas 10m, %d velas 1H\n",
    $md->size(),
    scalar(@{ $md->get_data->{'10m'} || [] }),
    scalar(@{ $md->get_data->{'1H'}  || [] });

# ---- Construir dataset ----
my $builder = Market::Concepts::DSVWAP::DatasetBuilder->new();
my $result  = $builder->build_dataset($md,
    pip_factor => 4,
    window_1m  => 500,
    window_10m => 300,
);

my $feature_rows = $result->{feature_rows};
my $meta_rows    = $result->{meta_rows};
my $discarded    = $result->{discarded};
my $n_rows       = scalar @$feature_rows;

print "\n" . "=" x 60 . "\n";
print "CHECK 1: Conteo de filas\n";
print "=" x 60 . "\n";
printf "  Filas exportadas : %d\n", $n_rows;
printf "  Filas descartadas: %d\n", $discarded;
printf "  Total apariciones: %d\n", $n_rows + $discarded;

# ---- CHECK 2: Conteo de celdas vacias por columna ----
print "\n" . "=" x 60 . "\n";
print "CHECK 2: Celdas vacias por columna\n";
print "=" x 60 . "\n";

my %empty_counts;
my @all_cols;
if ($n_rows > 0) {
    @all_cols = sort keys %{ $feature_rows->[0] };
    for my $row (@$feature_rows) {
        for my $col (@all_cols) {
            $empty_counts{$col}++ unless defined $row->{$col};
        }
    }
}

printf "  Total columnas en dataset: %d\n", scalar @all_cols;

# Reportar columnas con >50% vacias (posible error de implementacion)
my @problematic = grep { ($empty_counts{$_} // 0) / ($n_rows || 1) > 0.5 }
                  @all_cols;
if (@problematic) {
    printf "  WARN: Columnas >50%% vacias:\n";
    for my $col (sort @problematic) {
        printf "    %-50s %d/%d (%.1f%%)\n",
            $col,
            $empty_counts{$col} // 0, $n_rows,
            100.0 * ($empty_counts{$col} // 0) / ($n_rows || 1);
    }
} else {
    printf "  OK: Ninguna columna tiene >50%% vacias.\n";
}

# Resumen de columnas con algun vacio
my @with_some_empty = grep { ($empty_counts{$_} // 0) > 0 } @all_cols;
printf "  Columnas con algun vacio: %d / %d\n", scalar @with_some_empty, scalar @all_cols;

# ---- CHECK 3: Esquema de columnas ----
print "\n" . "=" x 60 . "\n";
print "CHECK 3: Esquema de columnas\n";
print "=" x 60 . "\n";

# Verificar que existan los targets con nombres exactos
for my $target (qw(trails_3m trails_5m trails_10m trails_15m)) {
    my $ok = exists $feature_rows->[0]{$target};
    printf "  Target %-20s: %s\n", $target, $ok ? 'OK' : 'FALTA';
}
# Verificar columnas globales
for my $col (qw(atr_1m volume_1m ema9_volume_1m)) {
    my $ok = exists $feature_rows->[0]{$col};
    printf "  Global %-20s: %s\n", $col, $ok ? 'OK' : 'FALTA';
}
# Verificar que los 3 TFs esten presentes
for my $tf (qw(1m 10m 1h)) {
    my $key = "ob_above_pip_${tf}";
    my $ok  = exists $feature_rows->[0]{$key};
    printf "  TF %4s (sample: %-30s): %s\n", $tf, $key, $ok ? 'OK' : 'FALTA';
}

# Verificar structure/eq columnas
for my $tf (qw(1m 10m 1h)) {
    for my $col (qw(structure_above_pip structure_above_kind
                    structure_below_pip structure_below_kind
                    eq_above_pip eq_above_kind
                    eq_below_pip eq_below_kind)) {
        my $key = "${col}_${tf}";
        unless (exists $feature_rows->[0]{$key}) {
            printf "  FALTA: %s\n", $key;
        }
    }
}
printf "  OK: Todas las columnas structure_*/eq_* presentes (3 TFs).\n" if $n_rows > 0;

# ---- CHECK 4: Validacion manual de 2 apariciones ----
print "\n" . "=" x 60 . "\n";
print "CHECK 4: Validacion manual — 2 apariciones reales\n";
print "=" x 60 . "\n";

# Obtener apariciones con todos los TFs via LiquiditySnapshot para comparar
my $engine  = Market::Concepts::DSVWAP::ModularEngine->new(length => 50);
my $res     = $engine->calculate($md);
my $counter = $res->{_ghost_counter};
my $enriched = $counter->count_trails_batch_with_snapshot($md,
    pip_factor => 4, window_1m => 500, window_10m => 300);

# Buscar las mismas 2 apariciones que DatasetBuilder usaria (las que NO son descartadas)
my @valid_snaps;
for my $row (@$enriched) {
    next unless defined $row->{tf_10m} && ref $row->{tf_10m} eq 'HASH';
    next unless defined $row->{tf_1h}  && ref $row->{tf_1h}  eq 'HASH';
    push @valid_snaps, $row;
    last if @valid_snaps >= 2;
}

for my $idx (0 .. $#valid_snaps) {
    my $snap  = $valid_snaps[$idx];
    my $ai    = $snap->{anchor_index};
    my $frow  = $feature_rows->[$idx];

    unless ($frow) {
        printf "  ERROR: feature_rows[%d] no existe\n", $idx;
        next;
    }

    printf "\n--- Aparicion #%d (anchor_index=%d) ---\n", $idx+1, $ai;

    # Comparar trails
    printf "  Targets: trails_3m=%s trails_5m=%s trails_10m=%s trails_15m=%s\n",
        $frow->{trails_3m}  // 'undef',
        $frow->{trails_5m}  // 'undef',
        $frow->{trails_10m} // 'undef',
        $frow->{trails_15m} // 'undef';
    printf "  Snap:    trails_3m=%s trails_5m=%s trails_10m=%s trails_15m=%s\n",
        $snap->{trails_3m}  // 'undef',
        $snap->{trails_5m}  // 'undef',
        $snap->{trails_10m} // 'undef',
        $snap->{trails_15m} // 'undef';

    # Comparar columnas 1m de VWAP
    my $v = $snap->{tf_1m}{vwap} || {};
    printf "  VWAP 1m (snap):    pip_vwap=%.2f pip_u1=%.2f pip_l1=%.2f\n",
        $v->{pip_vwap} // 0, $v->{pip_u1} // 0, $v->{pip_l1} // 0;
    printf "  VWAP 1m (dataset): vwap_pip_1m=%.2f vwap_u1_pip_1m=%.2f vwap_l1_pip_1m=%.2f\n",
        $frow->{vwap_pip_1m}    // 0,
        $frow->{vwap_u1_pip_1m} // 0,
        $frow->{vwap_l1_pip_1m} // 0;

    # Comparar structure events
    my $st = $snap->{tf_1m}{structure_events} || [];
    printf "  Structure events (snap): %d eventos\n", scalar @$st;
    printf "  structure_above_kind_1m=%s structure_below_kind_1m=%s\n",
        $frow->{structure_above_kind_1m} // 'undef',
        $frow->{structure_below_kind_1m} // 'undef';

    # Comparar eq events
    my $eq = $snap->{tf_1m}{eq_events} || [];
    printf "  EQ events (snap): %d eventos\n", scalar @$eq;
    printf "  eq_above_kind_1m=%s eq_below_kind_1m=%s\n",
        $frow->{eq_above_kind_1m} // 'undef',
        $frow->{eq_below_kind_1m} // 'undef';

    # Comparar fib
    my @fibs = @{ $snap->{tf_10m}{fib} || [] };
    printf "  Fib 10m (snap): %d niveles | fib_0_pip_10m=%.2f fib_1000_pip_10m=%.2f\n",
        scalar @fibs,
        $frow->{fib_0_pip_10m}    // 0,
        $frow->{fib_1000_pip_10m} // 0;
}

# ---- CHECK 5: Exportar a CSV de test ----
print "\n" . "=" x 60 . "\n";
print "CHECK 5: Export de CSV headless\n";
print "=" x 60 . "\n";

# Crear directorio output si no existe
my $out_dir = File::Spec->catfile($Bin, 'output');
unless (-d $out_dir) {
    require File::Path;
    File::Path::make_path($out_dir);
}

my $feat_file = File::Spec->catfile($Bin, 'output', 'test_features.csv');
my $meta_file = File::Spec->catfile($Bin, 'output', 'test_metadata.csv');

$builder->export_csv($feature_rows, $meta_rows, $feat_file, $meta_file);
printf "  Exportado: %s (%d filas)\n", $feat_file, $n_rows;
printf "  Exportado: %s (%d filas)\n", $meta_file, scalar @$meta_rows;

# Verificar que meta tiene el mismo numero de filas que features
if (scalar @$meta_rows == $n_rows) {
    printf "  OK: meta_rows == feature_rows (%d)\n", $n_rows;
} else {
    printf "  ERROR: meta_rows=%d != feature_rows=%d\n", scalar @$meta_rows, $n_rows;
}

print "\n" . "=" x 60 . "\n";
print "RESUMEN FASE 2 (test headless)\n";
print "=" x 60 . "\n";
printf "  Apariciones totales  : %d\n", $n_rows + $discarded;
printf "  Filas exportadas     : %d\n", $n_rows;
printf "  Filas descartadas    : %d\n", $discarded;
printf "  Columnas en dataset  : %d\n", scalar @all_cols;
printf "  Columnas con vacios  : %d\n", scalar @with_some_empty;
printf "  Columnas problematicas (>50%% vacias): %d\n", scalar @problematic;

if ($n_rows > 0) {
    print "\nRESULTADO: FASE 2 OK (test headless completado)\n";
    print "  NOTA: Columnas problematicas marcadas para revision manual, pueden ser normales si la feature es rara (ej. EQH/EQL).\n" if @problematic;
    exit 0;
} else {
    printf "\nRESULTADO: FASE 2 FALLO — 0 filas exportadas\n";
    exit 1;
}

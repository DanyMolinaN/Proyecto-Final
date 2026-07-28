#!/usr/bin/perl
use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;

use Market::MarketData;
use Market::Concepts::DSVWAP::ModularEngine;
use Market::Concepts::DSVWAP::LiquiditySnapshot;
use File::Spec;
use Time::Piece;

# ============================================================
# Script de validacion de Fase 1:
#   1. 10m se construye correctamente con build_timeframes
#   2. find_closed_tf_index: anti-leakage (devuelve bucket-1)
#   3. count_trails_batch_with_snapshot: tf_10m/tf_1h correctos
#   4. Monotonia de trails preservada (regresion de Fase 0)
# ============================================================

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

# ---- Cargar datos ----
my $csv_file = File::Spec->catfile($Bin, 'data', '2026_07_20.csv');
die "No se encuentra $csv_file\n" unless -f $csv_file;

my $md = Market::MarketData->new();
open(my $fh, '<', $csv_file) or die "No puedo abrir $csv_file: $!";
my $hdr = <$fh>;
my $count = 0;
while (my $line = <$fh>) {
    chomp $line;
    next unless $line =~ /\S/;
    my ($timestamp, $open, $high, $low, $close, $volume) = split /,/, $line;
    my $ts = parse_timestamp($timestamp);
    $md->add_candle({
        timestamp => $ts,
        open      => $open  + 0,
        high      => $high  + 0,
        low       => $low   + 0,
        close     => $close + 0,
        volume    => $volume + 0,
    });
    $count++;
}
close $fh;
print "MarketData size (1m): $count\n";

# ---- 1. Verificar que 10m se construye ----
$md->build_timeframes();
my $data = $md->get_data();
my $n10m = scalar @{ $data->{'10m'} || [] };
my $n15m = scalar @{ $data->{'15m'} || [] };
my $n1h  = scalar @{ $data->{'1H'}  || [] };
print "\n[1] Temporalidades construidas:\n";
printf "  10m: %d velas\n", $n10m;
printf "  15m: %d velas\n", $n15m;
printf "  1H : %d velas\n", $n1h;
die "ERROR: 10m no tiene velas!\n" unless $n10m > 0;
die "ERROR: 10m deberia tener aprox 1/10 de las velas de 1m (max=$count)\n" if $n10m > $count;
print "  OK\n";

# ---- 2. Anti-leakage: find_closed_tf_index ----
print "\n[2] Anti-leakage: find_closed_tf_index\n";

# Primera vela => el primer bucket de 10m la contiene => debe devolver undef
my $first_ts = $data->{'1m'}[0]{timestamp};
my $ci_first = $md->find_closed_tf_index('10m', $first_ts);
if (!defined $ci_first) {
    print "  OK primera vela => undef (sin bucket 10m previo cerrado)\n";
} else {
    print "  ERROR: esperaba undef para la primera vela, obtuve $ci_first\n";
}

# Vela a mitad del dataset
my $mid_idx = int($count / 2);
my $mid_ts  = $data->{'1m'}[$mid_idx]{timestamp};
my $ci_10m  = $md->find_closed_tf_index('10m', $mid_ts);
my $ci_1h   = $md->find_closed_tf_index('1H',  $mid_ts);

if (defined $ci_10m) {
    my $bk = $data->{'10m'}[$ci_10m];
    my $nxt = $data->{'10m'}[$ci_10m + 1];
    printf "  10m mid: closed idx=%d ts=%d\n", $ci_10m, $bk->{timestamp};
    if ($bk->{timestamp} < $mid_ts) {
        print "  [OK] bk_ts < mid_ts (no leakage)\n";
    } else {
        print "  [ERROR] LEAKAGE: bk_ts >= mid_ts!\n";
    }
    if ($nxt && $nxt->{timestamp} <= $mid_ts) {
        printf "  [OK] bucket_en_curso idx=%d ts=%d <= mid_ts=%d\n",
            $ci_10m+1, $nxt->{timestamp}, $mid_ts;
    }
} else {
    print "  WARN: 10m mid devolvio undef\n";
}
if (defined $ci_1h) {
    my $bk = $data->{'1H'}[$ci_1h];
    printf "  1H  mid: closed idx=%d ts=%d [OK]\n", $ci_1h, $bk->{timestamp};
}

# ---- 3. count_trails_batch_with_snapshot ----
print "\n[3] count_trails_batch_with_snapshot\n";

my $engine = Market::Concepts::DSVWAP::ModularEngine->new(length => 50);
my $result = $engine->calculate($md);

my $counter = $result->{_ghost_counter};
die "ERROR: _ghost_counter no presente en DTO\n" unless $counter;

my $enriched = $counter->count_trails_batch_with_snapshot($md);
my $total = scalar @$enriched;
print "  Total apariciones enriquecidas: $total\n";

my ($with_10m, $with_1h, $undef_10m, $undef_1h) = (0, 0, 0, 0);
my $monotony_broken = 0;
my $leakage_10m = 0;
my $leakage_1h  = 0;
my @sample_cases;

for my $row (@$enriched) {
    if (defined $row->{tf_10m}) {
        $with_10m++;
        # Verificar anti-leakage
        if (defined $row->{anchor_ts} && $row->{tf_10m}{ts} >= $row->{anchor_ts}) {
            $leakage_10m++;
        }
    } else {
        $undef_10m++;
    }
    if (defined $row->{tf_1h}) {
        $with_1h++;
        if (defined $row->{anchor_ts} && $row->{tf_1h}{ts} >= $row->{anchor_ts}) {
            $leakage_1h++;
        }
    } else {
        $undef_1h++;
    }

    my ($c3, $c5, $c10, $c15) = @{$row}{qw(trails_3m trails_5m trails_10m trails_15m)};
    unless ($c3 <= $c5 && $c5 <= $c10 && $c10 <= $c15) {
        $monotony_broken++;
    }

    if (@sample_cases < 3 && defined $row->{tf_10m}) {
        push @sample_cases, $row;
    }
}

printf "  Con tf_10m: %d  |  Sin tf_10m (undef): %d\n", $with_10m, $undef_10m;
printf "  Con tf_1h : %d  |  Sin tf_1h  (undef): %d\n", $with_1h,  $undef_1h;
printf "  Monotonia rota: %d (debe ser 0)\n", $monotony_broken;
printf "  Leakage 10m: %d (debe ser 0)\n", $leakage_10m;
printf "  Leakage 1H : %d (debe ser 0)\n", $leakage_1h;

die "ERROR: monotonia rota en $monotony_broken casos!\n"      if $monotony_broken > 0;
die "ERROR: LEAKAGE en tf_10m en $leakage_10m casos!\n"      if $leakage_10m > 0;
die "ERROR: LEAKAGE en tf_1h  en $leakage_1h  casos!\n"      if $leakage_1h  > 0;
die "ERROR: NINGUNA aparicion tiene tf_10m definido!\n"       if $with_10m == 0 && $total > 5;

# Completar muestra con casos undef si faltan
for my $row (@$enriched) {
    last if @sample_cases >= 3;
    push @sample_cases, $row;
}

print "\n[4] Muestra de 3 apariciones:\n";
print "-" x 70 . "\n";
for my $i (0..$#sample_cases) {
    my $r = $sample_cases[$i];
    printf "Caso %d | idx=%d precio=%.2f dir=%+d ts=%s\n",
        $i+1, $r->{anchor_index}, $r->{anchor_price}, $r->{anchor_dir},
        ($r->{anchor_ts} // 'undef');
    printf "  trails => 3m=%d 5m=%d 10m=%d 15m=%d\n",
        $r->{trails_3m}, $r->{trails_5m}, $r->{trails_10m}, $r->{trails_15m};
    if (defined $r->{tf_10m}) {
        printf "  tf_10m => idx=%d O=%.2f H=%.2f L=%.2f C=%.2f\n",
            $r->{tf_10m}{index}, $r->{tf_10m}{open}, $r->{tf_10m}{high},
            $r->{tf_10m}{low}, $r->{tf_10m}{close};
        printf "           bucket_ts=%d < anchor_ts=%d [%s]\n",
            $r->{tf_10m}{ts}, $r->{anchor_ts}//0,
            (defined $r->{anchor_ts} && $r->{tf_10m}{ts} < $r->{anchor_ts} ? 'OK' : 'LEAK!');
    } else {
        print "  tf_10m => undef (sin bucket cerrado)\n";
    }
    if (defined $r->{tf_1h}) {
        printf "  tf_1h  => idx=%d O=%.2f H=%.2f L=%.2f C=%.2f\n",
            $r->{tf_1h}{index}, $r->{tf_1h}{open}, $r->{tf_1h}{high},
            $r->{tf_1h}{low}, $r->{tf_1h}{close};
        printf "           bucket_ts=%d < anchor_ts=%d [%s]\n",
            $r->{tf_1h}{ts}, $r->{anchor_ts}//0,
            (defined $r->{anchor_ts} && $r->{tf_1h}{ts} < $r->{anchor_ts} ? 'OK' : 'LEAK!');
    } else {
        print "  tf_1h  => undef (sin bucket cerrado)\n";
    }
    print "\n";
}

print "=" x 70 . "\n";
print "RESULTADO: Fase 1 validada correctamente.\n";
printf "  10m: %d velas construidas\n", $n10m;
printf "  Anti-leakage: OK (0 casos de leakage en %d apariciones)\n", $total;
printf "  Monotonia: OK (0 rotos de %d)\n", $total;
printf "  Snapshots: %d con tf_10m, %d sin datos (apariciones tempranas)\n", $with_10m, $undef_10m;

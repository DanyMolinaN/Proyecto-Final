#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";

use Market::Indicators::ZigZag;
use Market::Indicators::ZigZagMTF;
use Market::Indicators::ZigZagVolumeProfile;

print "=== ZigZag Audit Test ===\n";

# --- Test 1: carga de modulos ---
print "[OK] ZigZag.pm cargado\n";
print "[OK] ZigZagMTF.pm cargado\n";
print "[OK] ZigZagVolumeProfile.pm cargado\n";

# --- Test 2: ZigZag con debug barra-por-barra ---
print "\n--- Test 2: debug barra-por-barra con 20 velas sinteticas ---\n";
my $zz = Market::Indicators::ZigZag->new(pivot_length => 3, debug => 1);

# Secuencia: sube, baja, sube (deberia generar 3 pivots H L H)
my @prices = (
    # low,  high
    [100, 102], [101, 104], [103, 107], [105, 106],  # sube -> ph en idx=2 o 3
    [104, 105], [102, 104], [100, 103],               # baja -> pl en idx=6
    [101, 105], [103, 108], [106, 110],               # sube -> ph en idx=9
    [108, 109], [106, 108], [104, 107],               # baja
);

my $ts = 1700000000;
my @candles;
for my $i (0 .. $#prices) {
    push @candles, {
        open      => $prices[$i][0],
        high      => $prices[$i][1],
        low       => $prices[$i][0] - 0.5,
        close     => $prices[$i][1] - 0.5,
        volume    => 1000,
        timestamp => $ts + $i * 60,
    };
}

print "  (output de debug va a STDERR)\n\n";
for my $i (0 .. $#candles) {
    $zz->update_at_index($candles[$i], $i);
}

my $pivots = $zz->get_pivots();
print "\n  Pivots resultantes:\n";
for my $p (@$pivots) {
    printf "    [%s] idx=%d  price=%.2f\n", $p->{kind}, $p->{index}, $p->{price};
}

# --- Test 3: Verificar que update NO crea pivots adicionales ---
print "\n--- Test 3: Live pivot se extiende sin crear duplicados ---\n";
my $zz2 = Market::Indicators::ZigZag->new(pivot_length => 3, debug => 0);
# Trend alcista: highs progresivamente mayores
my @highs = (100, 101, 103, 102, 105, 104, 106);
for my $i (0 .. $#highs) {
    $zz2->update_at_index({
        open => $highs[$i] - 1, high => $highs[$i],
        low  => $highs[$i] - 2, close => $highs[$i] - 0.5,
        volume => 1000, timestamp => $ts + $i * 60,
    }, $i);
}
my $p2 = $zz2->get_pivots();
my $h_count = scalar(grep { $_->{kind} eq 'H' } @$p2);
my $l_count = scalar(grep { $_->{kind} eq 'L' } @$p2);
printf "  H pivots=%d  L pivots=%d  (esperado: H=1, L<=1 en tendencia alcista pura)\n",
    $h_count, $l_count;

# --- Test 4: Verificar BUG #6 fix: pl-only bar con dir==1 no actualiza H ---
print "\n--- Test 4: BUG#6 - bar con solo pl y dir==1 NO debe actualizar pivot H ---\n";
my $zz3 = Market::Indicators::ZigZag->new(pivot_length => 3, debug => 1);
# Primero establecemos dir=1 con un pivot high
# periodo=3: idx 2 debe ser highest de [0,1,2]
$zz3->update_at_index({ open=>100, high=>101, low=>99.5, close=>100.5, volume=>1000, timestamp=>$ts+0 }, 0);
$zz3->update_at_index({ open=>101, high=>102, low=>100,  close=>101.5, volume=>1000, timestamp=>$ts+60 }, 1);
$zz3->update_at_index({ open=>102, high=>105, low=>101,  close=>104,   volume=>1000, timestamp=>$ts+120 }, 2);
# Ahora idx3: lowest de [1,2,3] -> low=99 -> pl=true, ph=false, dir==1 -> NO debe actualizar H pivot
$zz3->update_at_index({ open=>104, high=>104.5, low=>99, close=>100,   volume=>1000, timestamp=>$ts+180 }, 3);

my $p3 = $zz3->get_pivots();
printf "\n  Pivots con BUG#6 fix:\n";
for my $p (@$p3) {
    printf "    [%s] idx=%d  price=%.2f\n", $p->{kind}, $p->{index}, $p->{price};
}
my $last_h = (grep { $_->{kind} eq 'H' } @$p3)[-1];
if ($last_h && $last_h->{price} == 105) {
    print "  [PASS] El pivot H sigue en 105 (no fue sobreescrito por un low-only bar)\n";
} else {
    print "  [FAIL] El pivot H fue sobreescrito incorrectamente!\n";
}

print "\n=== Fin de auditoria ===\n";

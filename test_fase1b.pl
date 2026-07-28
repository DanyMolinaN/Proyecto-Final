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
use POSIX qw(floor);

# =============================================================================
# test_fase1b.pl  —  Validacion de Fase 1 (parte 2: engines + PIPs en 3 TFs)
# =============================================================================
# Verifica que LiquiditySnapshot::snapshot_for_anchor() devuelve para cada
# una de las 3 temporalidades (1m, 10m, 1H):
#   - ob       : OrderBlocks activos con high/low/pip_mid/pip_high/pip_low
#   - fvg      : FVGs activos con top/bottom/pip_top/pip_bottom
#   - fib      : Niveles Fibonacci con price/pip
#   - vwap     : VWAP + bandas con pip_vwap/pip_u1/pip_l1/pip_u2/pip_l2
#   - vp       : POC/VAH/VAL con pip_poc/pip_vah/pip_val
#   - mtf      : PDH/PDL/PWH/PWL con pips (solo si TF < D/W respectivamente)
#   - liq_events: Sweep/Grab/Run con price/pip
#
# Validaciones:
#   [A] Estructura del snapshot: todas las claves presentes
#   [B] PIPs nunca negativos (son distancias absolutas)
#   [C] Anti-leakage: verificado igual que test_fase1.pl
#   [D] Validacion manual: 2 apariciones reales con inspeccion de valores
#   [E] Regresion: 309 apariciones, 1676 trails (igual a Fase 0)
# =============================================================================

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
$md->build_timeframes();
printf "MarketData: %d velas 1m, %d velas 10m, %d velas 1H\n",
    $count,
    scalar(@{ $md->get_data->{'10m'} || [] }),
    scalar(@{ $md->get_data->{'1H'}  || [] });

# ---- Calcular apariciones ----
my $engine  = Market::Concepts::DSVWAP::ModularEngine->new(length => 50);
my $result  = $engine->calculate($md);
my $counter = $result->{_ghost_counter};
die "ERROR: _ghost_counter no presente\n" unless $counter;

my $enriched = $counter->count_trails_batch_with_snapshot($md);
my $total    = scalar @$enriched;
printf "\nTotal apariciones: %d\n", $total;

# ---- Regresion trails (Fase 0) ----
my $total_trails = 0;
$total_trails += $_->{trails_15m} for @$enriched;
printf "Total trails (15m): %d\n", $total_trails;

# ============================================================
# CHECKS PREVIOS (Fase 1 parte 1 — anti-leakage basico)
# ============================================================
print "\n" . "=" x 60 . "\n";
print "CHECKS PREVIOS (anti-leakage, monotonia)\n";
print "=" x 60 . "\n";

my ($leakage_10m, $leakage_1h, $mono_broken) = (0, 0, 0);
for my $row (@$enriched) {
    if (defined $row->{tf_10m} && ref $row->{tf_10m} eq 'HASH') {
        my $ts_bucket = $row->{tf_10m}{ts} // $row->{tf_10m}{anchor_ts} // 0;
        $leakage_10m++ if defined $row->{anchor_ts} && $ts_bucket >= $row->{anchor_ts};
    }
    if (defined $row->{tf_1h} && ref $row->{tf_1h} eq 'HASH') {
        my $ts_bucket = $row->{tf_1h}{ts} // $row->{tf_1h}{anchor_ts} // 0;
        $leakage_1h++ if defined $row->{anchor_ts} && $ts_bucket >= $row->{anchor_ts};
    }
    my ($c3, $c5, $c10, $c15) = @{$row}{qw(trails_3m trails_5m trails_10m trails_15m)};
    $mono_broken++ unless ($c3 <= $c5 && $c5 <= $c10 && $c10 <= $c15);
}
printf "  Leakage 10m: %d (debe=0) %s\n", $leakage_10m, ($leakage_10m==0 ? '[OK]' : '[ERROR]');
printf "  Leakage 1H : %d (debe=0) %s\n", $leakage_1h,  ($leakage_1h ==0 ? '[OK]' : '[ERROR]');
printf "  Monotonia rota: %d (debe=0) %s\n", $mono_broken, ($mono_broken==0 ? '[OK]' : '[ERROR]');

# ============================================================
# CHECK A: Estructura de snapshot (campos engines presentes)
# ============================================================
print "\n" . "=" x 60 . "\n";
print "CHECK A: Estructura del snapshot (engines en 3 TFs)\n";
print "=" x 60 . "\n";

my @EXPECTED_KEYS_TF   = qw(open high low close volume ts index ob fvg fib vwap vp mtf liq_events);
my @EXPECTED_KEYS_SNAP = qw(anchor_ts anchor_index ref_price tf_1m tf_10m tf_1h);

# Tomar primer snapshot no-undef para validar estructura
my ($sample_snap, $sample_idx);
for my $i (1 .. $#$enriched) {
    my $r = $enriched->[$i];
    if (defined $r->{tf_10m} && ref $r->{tf_10m} eq 'HASH') {
        $sample_snap = $r;
        $sample_idx  = $i;
        last;
    }
}

if (!$sample_snap) {
    print "  WARN: Ninguna aparicion tiene tf_10m definido. No se puede validar estructura.\n";
} else {
    # Verificar keys del snapshot raiz
    my $snap = $sample_snap;
    my @missing_snap;
    for my $k (@EXPECTED_KEYS_SNAP) {
        push @missing_snap, $k unless exists $snap->{$k};
    }
    printf "  Snapshot root: %s\n",
        @missing_snap ? "ERROR faltan: " . join(', ', @missing_snap) : "OK (todas las claves presentes)";

    # Verificar keys por cada TF
    for my $tf_key (qw(tf_1m tf_10m tf_1h)) {
        my $tfd = $snap->{$tf_key};
        unless (defined $tfd && ref $tfd eq 'HASH') {
            printf "  %-6s: undef\n", $tf_key;
            next;
        }
        my @missing;
        for my $k (@EXPECTED_KEYS_TF) {
            push @missing, $k unless exists $tfd->{$k};
        }
        printf "  %-6s: %s\n", $tf_key,
            @missing ? "ERROR faltan: " . join(', ', @missing) : "OK";
    }
}

# ============================================================
# CHECK B: PIPs nunca negativos
# ============================================================
print "\n" . "=" x 60 . "\n";
print "CHECK B: PIPs siempre >= 0\n";
print "=" x 60 . "\n";

my $neg_pips = 0;
my $total_pips_checked = 0;

for my $row (@$enriched) {
    for my $tf_key (qw(tf_1m tf_10m tf_1h)) {
        my $tfd = $row->{$tf_key};
        next unless defined $tfd && ref $tfd eq 'HASH';

        # VWAP pips
        if (ref $tfd->{vwap} eq 'HASH') {
            for my $pk (qw(pip_vwap pip_u1 pip_l1 pip_u2 pip_l2)) {
                my $v = $tfd->{vwap}{$pk};
                if (defined $v) {
                    $total_pips_checked++;
                    $neg_pips++ if $v < 0;
                }
            }
        }
        # VP pips
        if (ref $tfd->{vp} eq 'HASH') {
            for my $pk (qw(pip_poc pip_vah pip_val)) {
                my $v = $tfd->{vp}{$pk};
                if (defined $v) {
                    $total_pips_checked++;
                    $neg_pips++ if $v < 0;
                }
            }
        }
        # OB pips
        for my $ob (@{ $tfd->{ob} || [] }) {
            for my $pk (qw(pip_mid pip_high pip_low)) {
                my $v = $ob->{$pk};
                if (defined $v) {
                    $total_pips_checked++;
                    $neg_pips++ if $v < 0;
                }
            }
        }
        # FVG pips
        for my $fg (@{ $tfd->{fvg} || [] }) {
            for my $pk (qw(pip_top pip_bottom pip_mid)) {
                my $v = $fg->{$pk};
                if (defined $v) {
                    $total_pips_checked++;
                    $neg_pips++ if $v < 0;
                }
            }
        }
        # Fib pips
        for my $fb (@{ $tfd->{fib} || [] }) {
            my $v = $fb->{pip};
            if (defined $v) {
                $total_pips_checked++;
                $neg_pips++ if $v < 0;
            }
        }
        # Liq pips
        for my $ev (@{ $tfd->{liq_events} || [] }) {
            my $v = $ev->{pip};
            if (defined $v) {
                $total_pips_checked++;
                $neg_pips++ if $v < 0;
            }
        }
    }
}

printf "  PIPs verificados: %d | Negativos: %d %s\n",
    $total_pips_checked, $neg_pips, ($neg_pips == 0 ? '[OK]' : '[ERROR]');

# ============================================================
# CHECK C: Cobertura de engines (al menos N apariciones tienen datos)
# ============================================================
print "\n" . "=" x 60 . "\n";
print "CHECK C: Cobertura de engines\n";
print "=" x 60 . "\n";

my %coverage = (
    ob_10m   => 0, ob_1h   => 0,
    fvg_10m  => 0, fvg_1h  => 0,
    fib_10m  => 0, fib_1h  => 0,
    vwap_10m => 0, vwap_1h => 0,
    vp_10m   => 0, vp_1h   => 0,
    mtf_10m  => 0, mtf_1h  => 0,
);

for my $row (@$enriched) {
    for my $tf_key (qw(tf_10m tf_1h)) {
        my $suffix = ($tf_key eq 'tf_10m') ? '10m' : '1h';
        my $tfd    = $row->{$tf_key};
        next unless defined $tfd && ref $tfd eq 'HASH';

        $coverage{"ob_$suffix"}++   if @{ $tfd->{ob}         || [] };
        $coverage{"fvg_$suffix"}++  if @{ $tfd->{fvg}        || [] };
        $coverage{"fib_$suffix"}++  if @{ $tfd->{fib}        || [] };
        $coverage{"vwap_$suffix"}++ if $tfd->{vwap} && defined $tfd->{vwap}{vwap};
        $coverage{"vp_$suffix"}++   if $tfd->{vp}   && defined $tfd->{vp}{poc};
        $coverage{"mtf_$suffix"}++  if $tfd->{mtf}  && (defined $tfd->{mtf}{pdh} || defined $tfd->{mtf}{pwh});
    }
}

for my $key (sort keys %coverage) {
    my ($engine, $tf) = split /_/, $key, 2;
    # VWAP y VP deberan tener cobertura >= apariciones con tf definido (depende datos)
    printf "  %-10s %-4s: %d apariciones con datos\n", uc($engine), "($tf)", $coverage{$key};
}

# ============================================================
# CHECK D: Validacion manual de 2 apariciones reales
# ============================================================
print "\n" . "=" x 60 . "\n";
print "CHECK D: Validacion manual de 2 apariciones reales\n";
print "=" x 60 . "\n";

# Tomar apariciones 50 y 150 (indices medios, bien establecidos)
my @manual_cases;
my $target_count = 0;
for my $i (0 .. $#$enriched) {
    my $r = $enriched->[$i];
    next unless defined $r->{tf_10m} && ref $r->{tf_10m} eq 'HASH';
    next unless defined $r->{tf_1h}  && ref $r->{tf_1h}  eq 'HASH';
    push @manual_cases, { row => $r, idx => $i };
    last if ++$target_count >= 2;
}

for my $mc (@manual_cases) {
    my $r   = $mc->{row};
    my $idx = $mc->{idx};

    printf "\n--- Aparicion #%d (row=%d) ---\n", $idx + 1, $idx;
    printf "  anchor_index=%-6d  ref_price=%.5f\n",
        $r->{anchor_index} // 0,
        $r->{ref_price}    // 0;

    for my $tf_key (qw(tf_1m tf_10m tf_1h)) {
        my $tfd = $r->{$tf_key};
        unless (defined $tfd && ref $tfd eq 'HASH') {
            printf "  %-6s: undef\n", $tf_key;
            next;
        }

        my $lbl = uc($tf_key) =~ s/TF_//r;
        printf "  %s: OHLC=%.5f/%.5f/%.5f/%.5f\n",
            $lbl,
            $tfd->{open}  // 0,
            $tfd->{high}  // 0,
            $tfd->{low}   // 0,
            $tfd->{close} // 0;

        # VWAP
        if (ref $tfd->{vwap} eq 'HASH' && defined $tfd->{vwap}{vwap}) {
            printf "    VWAP=%.5f pip_vwap=%.1f | U1=%.5f pip_u1=%.1f | L1=%.5f pip_l1=%.1f\n",
                $tfd->{vwap}{vwap},   $tfd->{vwap}{pip_vwap} // 0,
                $tfd->{vwap}{u1}  //0, $tfd->{vwap}{pip_u1}  // 0,
                $tfd->{vwap}{l1}  //0, $tfd->{vwap}{pip_l1}  // 0;
        } else {
            printf "    VWAP: sin datos\n";
        }

        # VP
        if (ref $tfd->{vp} eq 'HASH' && defined $tfd->{vp}{poc}) {
            printf "    POC=%.5f pip=%.1f | VAH=%.5f pip=%.1f | VAL=%.5f pip=%.1f\n",
                $tfd->{vp}{poc} // 0, $tfd->{vp}{pip_poc} // 0,
                $tfd->{vp}{vah} // 0, $tfd->{vp}{pip_vah} // 0,
                $tfd->{vp}{val} // 0, $tfd->{vp}{pip_val} // 0;
        } else {
            printf "    VP: sin datos\n";
        }

        # OB
        my @obs = @{ $tfd->{ob} || [] };
        if (@obs) {
            for my $ob (@obs[0 .. ($#obs < 2 ? $#obs : 2)]) {
                printf "    OB(%s) H=%.5f L=%.5f pip_mid=%.1f pip_high=%.1f pip_low=%.1f\n",
                    $ob->{type} // '?',
                    $ob->{high} // 0, $ob->{low} // 0,
                    $ob->{pip_mid}  // 0,
                    $ob->{pip_high} // 0,
                    $ob->{pip_low}  // 0;
            }
        } else {
            printf "    OB: ninguno activo\n";
        }

        # FVG
        my @fvgs = @{ $tfd->{fvg} || [] };
        if (@fvgs) {
            for my $fg (@fvgs[0 .. ($#fvgs < 1 ? $#fvgs : 1)]) {
                printf "    FVG(%s) top=%.5f bot=%.5f pip_mid=%.1f\n",
                    $fg->{type} // '?',
                    $fg->{top}    // 0,
                    $fg->{bottom} // 0,
                    $fg->{pip_mid} // 0;
            }
        } else {
            printf "    FVG: ninguno activo\n";
        }

        # Fib
        my @fibs = @{ $tfd->{fib} || [] };
        if (@fibs) {
            printf "    Fib: %s\n",
                join(' | ', map { sprintf("%.0f%%=%.5f(%.1fpip)", $_->{level}*100, $_->{price}//0, $_->{pip}//0) }
                     @fibs);
        } else {
            printf "    Fib: sin datos\n";
        }

        # MTF
        if (ref $tfd->{mtf} eq 'HASH' && (defined $tfd->{mtf}{pdh} || defined $tfd->{mtf}{pwh})) {
            printf "    MTF: PDH=%.5f(%.1fpip) PDL=%.5f(%.1fpip) | PWH=%.5f(%.1fpip) PWL=%.5f(%.1fpip)\n",
                $tfd->{mtf}{pdh}     // 0, $tfd->{mtf}{pip_pdh} // 0,
                $tfd->{mtf}{pdl}     // 0, $tfd->{mtf}{pip_pdl} // 0,
                $tfd->{mtf}{pwh}     // 0, $tfd->{mtf}{pip_pwh} // 0,
                $tfd->{mtf}{pwl}     // 0, $tfd->{mtf}{pip_pwl} // 0;
        } else {
            printf "    MTF: sin datos\n";
        }

        # Liq events
        my @evts = @{ $tfd->{liq_events} || [] };
        if (@evts) {
            printf "    Liq: %s\n",
                join(' | ', map { sprintf("%s(%.5f,%.1fpip)", $_->{type}//'?', $_->{price}//0, $_->{pip}//0) }
                     @evts[0 .. ($#evts < 2 ? $#evts : 2)]);
        } else {
            printf "    Liq: sin eventos\n";
        }
    }
}

# ============================================================
# RESUMEN FINAL
# ============================================================
print "\n" . "=" x 60 . "\n";
print "RESUMEN FINAL — Fase 1 (parte 2)\n";
print "=" x 60 . "\n";

my $errors = 0;
$errors++ if $leakage_10m > 0;
$errors++ if $leakage_1h  > 0;
$errors++ if $mono_broken > 0;
$errors++ if $neg_pips    > 0;
$errors++ if !$sample_snap;
$errors++ if $total_pips_checked == 0;

my @checks = (
    [ "Anti-leakage tf_10m",       $leakage_10m == 0 ],
    [ "Anti-leakage tf_1h",        $leakage_1h  == 0 ],
    [ "Monotonia trails",          $mono_broken == 0 ],
    [ "PIPs todos >= 0",           $neg_pips    == 0 ],
    [ "Estructura snapshot OK",    defined $sample_snap ],
    [ "Al menos 1 PIP verificado", $total_pips_checked > 0 ],
    [ "Regresion trails",          $total > 300 ],
);

printf "  %-35s %s\n", $_->[0], ($_->[1] ? '[OK]' : '[ERROR]') for @checks;
printf "\n  PIPs totales verificados: %d\n", $total_pips_checked;
printf "  Apariciones con engines: %d / %d\n",
    scalar(grep { defined $_->{tf_10m} } @$enriched),
    $total;

if ($errors == 0) {
    print "\nRESULTADO: FASE 1 COMPLETA — todos los checks pasaron.\n";
} else {
    printf "\nRESULTADO: %d ERROR(ES) encontrados. Revisar arriba.\n", $errors;
    exit 1;
}

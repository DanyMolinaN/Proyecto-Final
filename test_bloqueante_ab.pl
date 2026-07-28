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
# test_bloqueante_ab.pl — Resolucion de los 3 bloqueantes pre-Fase-2
#
# BLOQUEANTE 1: pip_factor correcto para GC/MGC (Gold Futures COMEX)
#   Tick = $0.25  =>  pip_factor = 4  (1 pip = 1 tick = $0.25)
#   Rango esperado de distancias:
#     OB/FVG cercanos:   5-200  ticks  (~$1.25-$50)
#     VWAP:             10-500  ticks
#     MTF (PDH/PDL/PWH/PWL dentro del dia o semana): 10-2000 ticks
#
# BLOQUEANTE 2: A/B ventana deslizante
#   Comparar snapshot con window=500/300 vs window=99999 (full history)
#   para las primeras 5 apariciones validas con tf_10m definido.
#   Reportar diferencias en OB/FVG (engines que pueden perder niveles
#   formados antes de la ventana pero aun vigentes).
#
# BLOQUEANTE 3: Inspeccion manual de 1 aparicion
#   Imprimir snapshot completo de la aparicion #5 (bien establecida)
#   con todos los niveles para verificacion visual contra el chart.
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

# Obtener apariciones base (sin snapshot pesado)
my $base_results = $counter->count_trails_batch();
printf "Total apariciones: %d\n", scalar @$base_results;

# Construir indice ts_by_index (igual que en GhostTrailCounter)
my %ts_by_index;
for my $app (@{ $counter->{history_appearances} }) {
    $ts_by_index{ $app->{index} } = $app->{ts};
}

# Seleccionar primeras 5 apariciones con tf_10m disponible
# (para tener datos comparables en el A/B)
my @candidates;
{
    my $snap_tmp = Market::Concepts::DSVWAP::LiquiditySnapshot->new(
        pip_factor => 4,
        window_1m  => 9999999,
        window_10m => 9999999,
    );
    for my $row (@$base_results) {
        last if @candidates >= 5;
        my $ai = $row->{anchor_index};
        my $ts = $ts_by_index{$ai};
        unless (defined $ts) {
            my $c = eval { $md->get_candle_in_tf('1m', $ai) };
            $ts = $c->{timestamp} if $c;
        }
        next unless defined $ts;
        my $snap = $snap_tmp->snapshot_for_anchor($md, $ts, $ai);
        next unless defined $snap->{tf_10m} && ref $snap->{tf_10m} eq 'HASH';
        push @candidates, { row => $row, ts => $ts, snap_full => $snap };
    }
}

printf "\nApariciones candidatas para A/B: %d\n", scalar @candidates;

# =============================================================================
# BLOQUEANTE 1: pip_factor correcto
# =============================================================================
print "\n" . "=" x 70 . "\n";
print "BLOQUEANTE 1 — pip_factor correcto (GC/MGC Gold Futures)\n";
print "  Instrumento: COMEX Gold Futures (GC) / Micro Gold (MGC)\n";
print "  Tick size:   \$0.25 por troy oz\n";
print "  pip_factor:  4  (1 pip = 1 tick = \$0.25)\n";
print "=" x 70 . "\n\n";

# Verificar con pip_factor=4 sobre la primera aparicion candidata
if (@candidates) {
    my $snap = $candidates[0]{snap_full};
    my $rp   = $snap->{ref_price} // 0;
    printf "  Aparicion anchor_index=%d  ref_price=%.2f\n",
        $snap->{anchor_index} // 0, $rp;

    for my $tf_key (qw(tf_1m tf_10m tf_1h)) {
        my $tfd = $snap->{$tf_key};
        next unless defined $tfd && ref $tfd eq 'HASH';
        my $lbl = uc($tf_key) =~ s/TF_//r;
        printf "\n  [%s] close=%.2f\n", $lbl, $tfd->{close} // 0;

        if (ref $tfd->{vwap} eq 'HASH' && defined $tfd->{vwap}{vwap}) {
            printf "    VWAP     = %.2f  dist = %.1f ticks  (%.2f USD)\n",
                $tfd->{vwap}{vwap},
                $tfd->{vwap}{pip_vwap} // 0,
                ($tfd->{vwap}{pip_vwap} // 0) / 4;
        }
        if (my @obs = @{ $tfd->{ob} || [] }) {
            my $ob = $obs[0];
            printf "    OB(%s)  H=%.2f L=%.2f  mid_dist=%.1f ticks (%.2f USD)\n",
                $ob->{type} // '?',
                $ob->{high} // 0, $ob->{low} // 0,
                $ob->{pip_mid}  // 0,
                ($ob->{pip_mid} // 0) / 4;
        }
        if (ref $tfd->{mtf} eq 'HASH' && defined $tfd->{mtf}{pdh}) {
            printf "    PDH=%.2f  dist=%.1f ticks (%.2f USD)\n",
                $tfd->{mtf}{pdh} // 0,
                $tfd->{mtf}{pip_pdh} // 0,
                ($tfd->{mtf}{pip_pdh} // 0) / 4;
            printf "    PDL=%.2f  dist=%.1f ticks (%.2f USD)\n",
                $tfd->{mtf}{pdl} // 0,
                $tfd->{mtf}{pip_pdl} // 0,
                ($tfd->{mtf}{pip_pdl} // 0) / 4;
        }
    }
}

# Verificar que todos los pips de las 5 apariciones esten en rango razonable
my $pip_ok = 0; my $pip_bad = 0;
my $MAX_REASONABLE_TICKS = 20000;  # 20000 ticks = $5000 de distancia maxima razonable para GC
for my $c (@candidates) {
    my $snap = $c->{snap_full};
    for my $tf_key (qw(tf_1m tf_10m tf_1h)) {
        my $tfd = $snap->{$tf_key};
        next unless defined $tfd && ref $tfd eq 'HASH';
        if (ref $tfd->{vwap} eq 'HASH') {
            for my $pk (qw(pip_vwap pip_u1 pip_l1)) {
                my $v = $tfd->{vwap}{$pk} // next;
                ($v <= $MAX_REASONABLE_TICKS) ? $pip_ok++ : $pip_bad++;
            }
        }
        for my $ob (@{ $tfd->{ob} || [] }) {
            my $v = $ob->{pip_mid} // next;
            ($v <= $MAX_REASONABLE_TICKS) ? $pip_ok++ : $pip_bad++;
        }
    }
}
printf "\n  Pips en rango razonable (<= %d ticks): %d OK, %d fuera de rango %s\n",
    $MAX_REASONABLE_TICKS, $pip_ok, $pip_bad,
    ($pip_bad == 0 ? '[OK]' : '[ERROR - revisar pip_factor]');

# =============================================================================
# BLOQUEANTE 2: A/B ventana deslizante
# =============================================================================
print "\n" . "=" x 70 . "\n";
print "BLOQUEANTE 2 — A/B ventana deslizante (5 apariciones)\n";
print "  A = ventana completa (window_1m=99999, window_10m=99999)\n";
print "  B = ventana reducida (window_1m=500,   window_10m=300)\n";
print "=" x 70 . "\n";

my $snap_full = Market::Concepts::DSVWAP::LiquiditySnapshot->new(
    pip_factor => 4,
    window_1m  => 9999999,
    window_10m => 9999999,
);
my $snap_red = Market::Concepts::DSVWAP::LiquiditySnapshot->new(
    pip_factor => 4,
    window_1m  => 500,
    window_10m => 300,
);

my ($total_diffs, $total_same) = (0, 0);

for my $i (0 .. $#candidates) {
    my $c  = $candidates[$i];
    my $ai = $c->{row}{anchor_index};
    my $ts = $c->{ts};

    # Snap A (full) ya calculado
    my $sA = $c->{snap_full};

    # Snap B (reducido) — calcular ahora
    my $sB = $snap_red->snapshot_for_anchor($md, $ts, $ai);

    printf "\n  --- Aparicion %d (anchor=%d) ---\n", $i+1, $ai;

    for my $tf_key (qw(tf_1m tf_10m tf_1h)) {
        my $A = $sA->{$tf_key};
        my $B = $sB->{$tf_key};
        next unless defined $A && ref $A eq 'HASH';
        next unless defined $B && ref $B eq 'HASH';

        my $lbl = uc($tf_key) =~ s/TF_//r;

        # Comparar OBs: numero y precios
        my @obA = @{ $A->{ob}  || [] };
        my @obB = @{ $B->{ob}  || [] };
        my $ob_same = (@obA == @obB);
        if (!$ob_same) {
            printf "    [%s] OB DIFIERE: A=%d bloques, B=%d bloques\n",
                $lbl, scalar @obA, scalar @obB;
            # Mostrar cuales faltan en B
            my %prices_B = map { sprintf("%.2f", $_->{price} // 0) => 1 } @obB;
            for my $ob (@obA) {
                my $pk = sprintf("%.2f", $ob->{price} // 0);
                unless ($prices_B{$pk}) {
                    printf "      [FALTA en B] OB(%s) H=%.2f L=%.2f idx=%d\n",
                        $ob->{type}//'?', $ob->{high}//0, $ob->{low}//0, $ob->{index}//0;
                }
            }
            $total_diffs++;
        } else {
            $total_same++;
        }

        # Comparar FVGs: numero y precios
        my @fvgA = @{ $A->{fvg} || [] };
        my @fvgB = @{ $B->{fvg} || [] };
        my $fvg_same = (@fvgA == @fvgB);
        if (!$fvg_same) {
            printf "    [%s] FVG DIFIERE: A=%d activos, B=%d activos\n",
                $lbl, scalar @fvgA, scalar @fvgB;
            my %tops_B = map { sprintf("%.2f", $_->{top} // 0) => 1 } @fvgB;
            for my $fvg (@fvgA) {
                my $tk = sprintf("%.2f", $fvg->{top} // 0);
                unless ($tops_B{$tk}) {
                    printf "      [FALTA en B] FVG(%s) top=%.2f bot=%.2f idx=%d\n",
                        $fvg->{type}//'?', $fvg->{top}//0, $fvg->{bottom}//0, $fvg->{index}//0;
                }
            }
            $total_diffs++;
        } else {
            $total_same++;
        }

        # VWAP: diferencia relativa (debe ser 0 si ventana incluye todo)
        if (ref $A->{vwap} eq 'HASH' && ref $B->{vwap} eq 'HASH'
            && defined $A->{vwap}{vwap} && defined $B->{vwap}{vwap}) {
            my $diff_vwap = abs(($A->{vwap}{vwap} // 0) - ($B->{vwap}{vwap} // 0));
            if ($diff_vwap > 0.01) {
                printf "    [%s] VWAP DIFIERE: A=%.4f B=%.4f delta=%.4f\n",
                    $lbl, $A->{vwap}{vwap}, $B->{vwap}{vwap}, $diff_vwap;
                $total_diffs++;
            } else {
                $total_same++;
            }
        }
    }
}

printf "\n  RESULTADO A/B: %d coincidencias, %d diferencias\n",
    $total_same, $total_diffs;
if ($total_diffs > 0) {
    print "  [ATENCION] Diferencias encontradas — revisar ventana o justificar\n";
} else {
    print "  [OK] Ventana reducida produce resultados identicos a full history\n";
}

# =============================================================================
# BLOQUEANTE 3: Inspeccion manual de aparicion #5 (o la ultima disponible)
# =============================================================================
print "\n" . "=" x 70 . "\n";
print "BLOQUEANTE 3 — Inspeccion manual completa de aparicion\n";
print "  Usar para verificar contra chart de TradingView / chart interno\n";
print "=" x 70 . "\n";

my $manual = $candidates[-1];  # ultima de las 5 candidatas
unless ($manual) {
    print "  No hay aparicion candidata disponible.\n";
    exit 0;
}

my $snap = $manual->{snap_full};
my $ai   = $snap->{anchor_index} // 0;

# Obtener timestamp legible
my $ts_epoch = $manual->{ts} // 0;
my $ts_str = eval { Time::Piece->new($ts_epoch)->strftime('%Y-%m-%d %H:%M:%S UTC') } // $ts_epoch;

printf "\n  Aparicion anchor_index=%d  ts=%s\n", $ai, $ts_str;
printf "  ref_price (HLC3 de la vela de aparicion): %.4f\n\n", $snap->{ref_price} // 0;

for my $tf_key (qw(tf_1m tf_10m tf_1h)) {
    my $tfd = $snap->{$tf_key};
    my $lbl = uc($tf_key) =~ s/TF_//r;

    unless (defined $tfd && ref $tfd eq 'HASH') {
        printf "  [%s] undef (sin bucket cerrado disponible)\n\n", $lbl;
        next;
    }

    printf "  [%s] ts_bucket=%s  index_en_TF=%d\n", $lbl,
        do {
            eval { Time::Piece->new($tfd->{ts} // 0)->strftime('%Y-%m-%d %H:%M') } // ($tfd->{ts} // '?')
        },
        $tfd->{index} // 0;
    printf "    OHLC: %.2f / %.2f / %.2f / %.2f   Vol: %.0f\n",
        $tfd->{open}//0, $tfd->{high}//0, $tfd->{low}//0, $tfd->{close}//0, $tfd->{volume}//0;

    # VWAP
    if (ref $tfd->{vwap} eq 'HASH' && defined $tfd->{vwap}{vwap}) {
        printf "    VWAP:  %.4f  (%+.1f ticks desde ref)\n",
            $tfd->{vwap}{vwap},
            ($tfd->{vwap}{pip_vwap} // 0) * (($tfd->{vwap}{vwap} > ($snap->{ref_price}//0)) ? 1 : -1);
        printf "    Bandas: U1=%.4f(+%.1ft) L1=%.4f(-%.1ft) | U2=%.4f(+%.1ft) L2=%.4f(-%.1ft)\n",
            $tfd->{vwap}{u1}//0, $tfd->{vwap}{pip_u1}//0,
            $tfd->{vwap}{l1}//0, $tfd->{vwap}{pip_l1}//0,
            $tfd->{vwap}{u2}//0, $tfd->{vwap}{pip_u2}//0,
            $tfd->{vwap}{l2}//0, $tfd->{vwap}{pip_l2}//0;
    } else { printf "    VWAP: sin datos\n"; }

    # VP
    if (ref $tfd->{vp} eq 'HASH' && defined $tfd->{vp}{poc}) {
        printf "    VP:    POC=%.4f(%.1ft) VAH=%.4f(%.1ft) VAL=%.4f(%.1ft)\n",
            $tfd->{vp}{poc}//0, $tfd->{vp}{pip_poc}//0,
            $tfd->{vp}{vah}//0, $tfd->{vp}{pip_vah}//0,
            $tfd->{vp}{val}//0, $tfd->{vp}{pip_val}//0;
    } else { printf "    VP: sin datos\n"; }

    # OBs (todos)
    my @obs = @{ $tfd->{ob} || [] };
    if (@obs) {
        for my $ob (@obs) {
            printf "    OB(%s,%s) H=%.4f L=%.4f | mid=%.1ft high=%.1ft low=%.1ft | idx=%d\n",
                $ob->{type}//'?', $ob->{kind}//'?',
                $ob->{high}//0, $ob->{low}//0,
                $ob->{pip_mid}//0, $ob->{pip_high}//0, $ob->{pip_low}//0,
                $ob->{index}//0;
        }
    } else { printf "    OB: ninguno activo\n"; }

    # FVGs (todos)
    my @fvgs = @{ $tfd->{fvg} || [] };
    if (@fvgs) {
        for my $f (@fvgs) {
            printf "    FVG(%s,st=%s) top=%.4f bot=%.4f | mid=%.1ft top=%.1ft bot=%.1ft | idx=%d\n",
                $f->{type}//'?', $f->{state}//'?',
                $f->{top}//0, $f->{bottom}//0,
                $f->{pip_mid}//0, $f->{pip_top}//0, $f->{pip_bottom}//0,
                $f->{index}//0;
        }
    } else { printf "    FVG: ninguno activo\n"; }

    # Fib
    my @fibs = @{ $tfd->{fib} || [] };
    if (@fibs) {
        printf "    Fib: %s\n",
            join(' | ', map { sprintf("%.0f%%=%.4f(%.1ft)", $_->{level}*100, $_->{price}//0, $_->{pip}//0) }
                 @fibs);
    } else { printf "    Fib: sin datos\n"; }

    # MTF
    if (ref $tfd->{mtf} eq 'HASH') {
        printf "    MTF: PDH=%.4f(%.1ft) PDL=%.4f(%.1ft)\n",
            $tfd->{mtf}{pdh}//0, $tfd->{mtf}{pip_pdh}//0,
            $tfd->{mtf}{pdl}//0, $tfd->{mtf}{pip_pdl}//0
            if defined $tfd->{mtf}{pdh};
        printf "         PWH=%.4f(%.1ft) PWL=%.4f(%.1ft)\n",
            $tfd->{mtf}{pwh}//0, $tfd->{mtf}{pip_pwh}//0,
            $tfd->{mtf}{pwl}//0, $tfd->{mtf}{pip_pwl}//0
            if defined $tfd->{mtf}{pwh};
    } else { printf "    MTF: sin datos\n"; }

    # Liq events
    my @evts = @{ $tfd->{liq_events} || [] };
    if (@evts) {
        printf "    Liq: %s\n",
            join(' | ', map { sprintf("%s(%.4f,%.1ft,idx=%d)", $_->{type}//'?', $_->{price}//0, $_->{pip}//0, $_->{index}//0) } @evts);
    } else { printf "    Liq: sin eventos\n"; }

    print "\n";
}

print "=" x 70 . "\n";
print "Para verificar en chart: buscar la vela con anchor_index y ts mostrado.\n";
print "Comparar OB/FVG/VWAP contra los overlays del chart en esa barra.\n";
print "=" x 70 . "\n";

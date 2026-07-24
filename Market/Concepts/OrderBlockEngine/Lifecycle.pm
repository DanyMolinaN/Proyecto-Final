package Market::Concepts::OrderBlockEngine;

# =============================================================================
# OrderBlockEngine::Lifecycle
# =============================================================================
# Ciclo de vida, deduplicacion y ATR auxiliar.
# Continuacion de Market::Concepts::OrderBlockEngine (SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _apply_lifecycle {
    my ($self, $blocks, $candles, $last_index) = @_;

    for my $ob (@$blocks) {
        my $start  = $ob->{confirmation_index};
        next unless defined $start;

        my $ob_high   = $ob->{high};
        my $ob_low    = $ob->{low};
        my $height    = $ob_high - $ob_low;
        next if $height <= 0;

        my $type      = $ob->{type};
        my $state     = 'Detected';
        my $max_pct   = 0;
        my $mit_idx   = undef;
        my $inv_idx   = undef;

        for (my $i = $start; $i <= $last_index; $i++) {
            my $c = $candles->[$i];
            next unless $c;

            if ($type eq 'bullish') {
                # ── Invalidación: cierre bajo el OB ──────────────────────
                if ($c->{close} < $ob_low) {
                    $state   = 'Invalidated';
                    $inv_idx = $i;
                    last;
                }
                # ── Penetración de la zona ────────────────────────────────
                if ($c->{low} < $ob_high) {
                    my $pct = ($ob_high - $c->{low}) / $height * 100;
                    $pct = 100 if $pct > 100;
                    if ($pct > $max_pct) { $max_pct = $pct; }
                    if ($max_pct >= 50 && $state eq 'Detected') {
                        $state   = 'Mitigated';
                        $mit_idx = $i;
                    }
                }
            }
            else { # bearish
                # ── Invalidación: cierre sobre el OB ─────────────────────
                if ($c->{close} > $ob_high) {
                    $state   = 'Invalidated';
                    $inv_idx = $i;
                    last;
                }
                # ── Penetración de la zona ────────────────────────────────
                if ($c->{high} > $ob_low) {
                    my $pct = ($c->{high} - $ob_low) / $height * 100;
                    $pct = 100 if $pct > 100;
                    if ($pct > $max_pct) { $max_pct = $pct; }
                    if ($max_pct >= 50 && $state eq 'Detected') {
                        $state   = 'Mitigated';
                        $mit_idx = $i;
                    }
                }
            }
        }

        $ob->{state}             = $state;
        $ob->{mitigated_index}   = $mit_idx;
        $ob->{invalidated_index} = $inv_idx;
        $ob->{mitigation_pct}    = int($max_pct + 0.5);
    }
}

# =============================================================================
# PRIVATE — _deduplicate(\@blocks)  →  @unique
#
# Si varios eventos BOS/CHoCH consecutivos apuntan a la misma vela OB (mismo
# $ob_idx), conserva solo el más reciente para ese índice.
# =============================================================================
sub _deduplicate {
    my ($blocks) = @_;
    my %seen;
    my @out;
    # Procesa en orden inverso para quedarse con el más reciente
    for my $b (reverse @$blocks) {
        my $key = join(':', $b->{index}, $b->{type});
        next if $seen{$key}++;
        unshift @out, $b;
    }
    return @out;
}

# =============================================================================
# PRIVATE — _compute_atr(\@candles, $last_idx, $period)
# =============================================================================
sub _compute_atr {
    my ($candles, $last_idx, $period) = @_;
    return 1.0 if $last_idx < 1;
    my $start = $last_idx - $period + 1;
    $start = 1 if $start < 1;
    my ($sum, $count) = (0, 0);
    for my $i ($start .. $last_idx) {
        my $c  = $candles->[$i]     or next;
        my $cp = $candles->[$i - 1] or next;
        my $hl = $c->{high} - $c->{low};
        my $hc = abs($c->{high} - $cp->{close});
        my $lc = abs($c->{low}  - $cp->{close});
        my $tr = $hl > $hc ? $hl : $hc;
        $tr = $lc if $lc > $tr;
        $sum += $tr; $count++;
    }
    return $count > 0 ? $sum / $count : 1.0;
}

1;

__END__

=pod

=head1 NAME

Market::Concepts::OrderBlockEngine — Motor de Order Blocks SMC v2

=head1 SYNOPSIS

    # Opción A: pasar el resultado del SMCStructureEngine directamente
    my $smc_result = $smc_engine->calculate($market_data, %args);
    my $ob_result  = $ob_engine->calculate($market_data, $smc_result, %args);

    # Opción B: pasar el objeto engine (se llama a ->events())
    my $ob_result  = $ob_engine->calculate($market_data, $smc_engine, %args);

    # Opción C: compatibilidad con el legacy StructureEngine
    my $ob_result  = $ob_engine->calculate($market_data, $structure_engine, %args);

    for my $ob (@{ $ob_result->{blocks} }) {
        printf "OB %s [%s] idx=%d  %.4f..%.4f  state=%s\n",
            $ob->{type}, $ob->{kind}, $ob->{index},
            $ob->{low}, $ob->{high}, $ob->{state};
    }

=head1 DESCRIPTION

Un Order Block (OB) nace ÚNICAMENTE cuando el SMCStructureEngine detecta un
BOS o CHoCH. La vela institucional que define la zona (High/Low) se localiza
buscando el extremo más pronunciado en el rango de velas entre el Swing
pivote y la vela de confirmación:

    BOS/CHoCH alcista → zona de DEMANDA (OB bullish)
        Vela OB = la de menor parsed_low  en [swing_index .. break_index-1]

    BOS/CHoCH bajista → zona de OFERTA (OB bearish)
        Vela OB = la de mayor parsed_high en [swing_index .. break_index-1]

La mitigación se activa cuando el precio penetra >= 50% de la zona.
La invalidación ocurre cuando el close cierra al otro lado del OB.

=cut

1;

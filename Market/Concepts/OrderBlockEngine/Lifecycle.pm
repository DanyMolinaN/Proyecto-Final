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

        my $swing_idx = $ob->{swing_index};
        my $inv_level;
        if (defined $swing_idx && $candles->[$swing_idx]) {
            $inv_level = $type eq 'bullish' ? $candles->[$swing_idx]->{low} : $candles->[$swing_idx]->{high};
        } else {
            $inv_level = $type eq 'bullish' ? $ob_low : $ob_high;
        }

        for (my $i = $start; $i <= $last_index; $i++) {
            my $c = $candles->[$i];
            next unless $c;

            if ($type eq 'bullish') {
                # ── Penetración de la zona ────────────────────────────────
                if ($c->{low} < $ob_high) {
                    my $pct = ($ob_high - $c->{low}) / $height * 100;
                    $pct = 100 if $pct > 100;
                    if ($pct > $max_pct) { $max_pct = $pct; }
                }

                # ── Invalidación: cierre bajo el swing original ──────────
                if ($c->{close} < $inv_level) {
                    $state   = 'Invalidated';
                    $inv_idx = $i;
                    last;
                }
                # ── Mitigación Total: cierre bajo el OB ──────────────────
                elsif ($c->{close} < $ob_low) {
                    if ($state ne 'Mitigated' && $state ne 'Invalidated') {
                        $state   = 'Mitigated';
                        $mit_idx = $i unless defined $mit_idx;
                    }
                }
                # ── Penetración Parcial ──────────────────────────────────
                elsif ($max_pct >= 50 && $state eq 'Detected') {
                    $state   = 'PartiallyMitigated';
                    $mit_idx = $i;
                }
            }
            else { # bearish
                # ── Penetración de la zona ────────────────────────────────
                if ($c->{high} > $ob_low) {
                    my $pct = ($c->{high} - $ob_low) / $height * 100;
                    $pct = 100 if $pct > 100;
                    if ($pct > $max_pct) { $max_pct = $pct; }
                }

                # ── Invalidación: cierre sobre el swing original ─────────
                if ($c->{close} > $inv_level) {
                    $state   = 'Invalidated';
                    $inv_idx = $i;
                    last;
                }
                # ── Mitigación Total: cierre sobre el OB ─────────────────
                elsif ($c->{close} > $ob_high) {
                    if ($state ne 'Mitigated' && $state ne 'Invalidated') {
                        $state   = 'Mitigated';
                        $mit_idx = $i unless defined $mit_idx;
                    }
                }
                # ── Penetración Parcial ──────────────────────────────────
                elsif ($max_pct >= 50 && $state eq 'Detected') {
                    $state   = 'PartiallyMitigated';
                    $mit_idx = $i;
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
# PRIVATE — _filter_overlaps(\@blocks)  →  @filtered
#
# Elimina solapamientos > 50% entre bloques del mismo tipo. Se conserva el
# de break_index más reciente.
# =============================================================================
sub _filter_overlaps {
    my ($self, $blocks) = @_;
    my @sorted = sort { $b->{break_index} <=> $a->{break_index} } @$blocks;
    my @kept;
    for my $b (@sorted) {
        my $overlap = 0;
        for my $k (@kept) {
            next if $b->{type} ne $k->{type};
            my $max_low = $b->{low} > $k->{low} ? $b->{low} : $k->{low};
            my $min_high = $b->{high} < $k->{high} ? $b->{high} : $k->{high};
            if ($min_high > $max_low) {
                my $intersection = $min_high - $max_low;
                my $h1 = $b->{high} - $b->{low};
                my $h2 = $k->{high} - $k->{low};
                my $min_h = $h1 < $h2 ? $h1 : $h2;
                if ($min_h > 0 && ($intersection / $min_h) > 0.5) {
                    $overlap = 1;
                    last;
                }
            }
        }
        push @kept, $b unless $overlap;
    }
    # Restore original order (by break_index ascending)
    return reverse @kept;
}

# =============================================================================
# PRIVATE — _compute_atr(\@candles, $last_idx, $period)
# =============================================================================
sub _compute_atr_series {
    my ($candles, $last_idx, $period) = @_;
    my @atr;
    $#atr = $last_idx;
    return \@atr if $last_idx < 1;
    
    my $sum_tr = 0;
    my $count  = 0;
    my $alpha  = 1.0 / $period;
    
    for my $i (1 .. $last_idx) {
        my $c  = $candles->[$i];
        my $cp = $candles->[$i - 1];
        next unless $c && $cp;
        
        my $hl = $c->{high} - $c->{low};
        my $hc = abs($c->{high} - $cp->{close});
        my $lc = abs($c->{low}  - $cp->{close});
        my $tr = $hl > $hc ? $hl : $hc;
        $tr = $lc if $lc > $tr;
        
        if (!defined $atr[$i - 1]) {
            $sum_tr += $tr;
            $count++;
            if ($count == $period) {
                $atr[$i] = $sum_tr / $period;
            }
        } else {
            $atr[$i] = $alpha * $tr + (1 - $alpha) * $atr[$i - 1];
        }
    }
    
    # Fill leading missing values with the first valid ATR or 1.0
    my $first_valid = 1.0;
    for my $i (0 .. $last_idx) {
        if (defined $atr[$i]) {
            $first_valid = $atr[$i];
            last;
        }
    }
    for my $i (0 .. $last_idx) {
        $atr[$i] //= $first_valid;
    }
    
    return \@atr;
}

# =============================================================================
# PRIVATE — _compute_volume_percentile(\@candles, $idx, $period)
# =============================================================================
sub _compute_volume_percentile {
    my ($candles, $idx, $period) = @_;
    my $start = $idx - $period + 1;
    $start = 0 if $start < 0;
    my @vols;
    for my $i ($start .. $idx) {
        my $c = $candles->[$i];
        push @vols, $c->{volume} // 0 if $c;
    }
    return 100 unless @vols > 0;
    my $target_vol = $candles->[$idx]->{volume} // 0;
    my $less_count = 0;
    for my $v (@vols) {
        $less_count++ if $v < $target_vol;
    }
    return ($less_count / scalar(@vols)) * 100;
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

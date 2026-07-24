package Market::Concepts::OrderBlockEngine;

# =============================================================================
# OrderBlockEngine::Detect
# =============================================================================
# Extraccion de eventos y localizacion de vela OB.
# Continuacion de Market::Concepts::OrderBlockEngine (SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _extract_events {
    my ($self, $src, $vis) = @_;
    return [] unless $src;

    my @raw;

    if (ref $src eq 'HASH') {
        # ── Resultado directo de SMCStructureEngine ───────────────────────
        if (exists $src->{events}) {
            @raw = @{ $src->{events} };
        }
        # ── Legacy StructureEngine resultado ─────────────────────────────
        elsif (exists $src->{breaks}) {
            @raw = map {
                {
                    kind        => $_->{kind}      // 'BOS',
                    direction   => $_->{direction} // 'bullish',
                    scope       => $_->{scope}     // 'swing',
                    index       => $_->{index}     // $_->{confirmation_index},
                    swing_index => $_->{swing_index} // $_->{break_index},
                }
            } @{ $src->{breaks} || [] };
        }
    }
    elsif (ref $src && $src->can('events')) {
        # ── Objeto SMCStructureEngine ─────────────────────────────────────
        @raw = @{ $src->events() };
    }
    elsif (ref $src && $src->can('structure')) {
        # ── Objeto Legacy StructureEngine ─────────────────────────────────
        my $st = $src->structure() || {};
        for my $br (@{ $st->{breaks} || [] }) {
            push @raw, {
                kind        => $br->{kind}        // 'BOS',
                direction   => $br->{direction}   // 'bullish',
                scope       => $br->{scope}       // 'swing',
                index       => $br->{index}       // $br->{confirmation_index},
                swing_index => $br->{swing_index} // $br->{break_index},
            };
        }
    }

    # Filtra por visible_limit y sólo BOS/CHoCH (no EQH/EQL)
    my @filtered;
    for my $e (@raw) {
        next unless ($e->{kind} // '') =~ /^(?:BOS|CHoCH)$/;
        next if defined $vis && ($e->{index} // 0) > $vis;
        push @filtered, $e;
    }

    return \@filtered;
}

# =============================================================================
# PRIVATE — _find_ob_candle(\@candles, \@ph, \@pl, $from, $to, $dir) → $idx
#
# LuxAlgo busca dentro del rango de velas [from..to] la "vela institucional"
# que será el Order Block:
#
#   BOS/CHoCH BULLISH  (ruptura alcista desde un Swing LOW):
#     → Se busca la vela con el parsed_low MÍNIMO dentro del rango.
#       Es la vela que penetró más profundo antes del impulso.
#
#   BOS/CHoCH BEARISH  (ruptura bajista desde un Swing HIGH):
#     → Se busca la vela con el parsed_high MÁXIMO dentro del rango.
#       Es la vela que subió más alto antes del impulso.
#
# El LuxAlgo Pine Script original usa:
#   bearish: a_rray = parsedHighs.slice(p_ivot.barIndex, bar_index)
#            parsedIndex = p_ivot.barIndex + a_rray.indexof(a_rray.max())
#   bullish: a_rray = parsedLows.slice(...)
#            parsedIndex = p_ivot.barIndex + a_rray.indexof(a_rray.min())
# =============================================================================
sub _find_ob_candle {
    my ($self, $candles, $ph, $pl, $from, $to, $dir) = @_;

    return undef if $from > $to;

    my ($best_idx, $best_val);

    if ($dir eq 'bullish') {
        # Busca el mínimo parsed_low en el rango
        for my $i ($from .. $to) {
            my $val = $pl->[$i];
            next unless defined $val;
            if (!defined $best_val || $val < $best_val) {
                $best_val = $val;
                $best_idx = $i;
            }
        }
    }
    else {
        # Busca el máximo parsed_high en el rango
        for my $i ($from .. $to) {
            my $val = $ph->[$i];
            next unless defined $val;
            if (!defined $best_val || $val > $best_val) {
                $best_val = $val;
                $best_idx = $i;
            }
        }
    }

    return $best_idx;
}

# =============================================================================
# PRIVATE — _apply_lifecycle(\@blocks, \@candles, $last_index)
#
# Itera las velas DESPUÉS de la confirmación del OB y aplica:
#
#   OB BULLISH (zona de demanda — el precio debería rebotar desde allí):
#     • Mitigación : alguna vela posterior entra en la zona (low <= ob.high)
#                    y el grado de penetración supera el umbral (50 %)
#     • Invalidación: close < ob.low  (el precio cierra bajo el OB → zona rota)
#
#   OB BEARISH (zona de oferta):
#     • Mitigación : high >= ob.low  y penetración > 50 %
#     • Invalidación: close > ob.high
#
# El porcentaje de mitigación se calcula como la fracción de la zona que ha
# sido "consumida" por el precio:
#   bullish: pct = (ob.high - vela.low)  / (ob.high - ob.low) × 100
#   bearish: pct = (vela.high - ob.low)  / (ob.high - ob.low) × 100
# =============================================================================

1;

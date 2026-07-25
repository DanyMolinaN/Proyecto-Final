package Market::Concepts::SMCStructureEngine;

# =============================================================================
# SMCStructureEngine::Breaks
# =============================================================================
# BOS/CHoCH con crossover/crossunder de close (igual que Pine / David):
#   bullish: prev.close <= level && cur.close > level
#   bearish: prev.close >= level && cur.close < level
#
# Doble punta: al formarse un nuevo pivote same-side, Pivots.pm resetea
# crossed=0 y reemplaza el nivel — aqui solo confirmamos el cruce.
# =============================================================================

use strict;
use warnings;

sub _check_structure_break {
    my ($self, $candles, $i, %o) = @_;
    my $c = $candles->[$i];
    return unless $c;
    my $prev = $i > 0 ? $candles->[$i - 1] : undef;
    return unless $prev;   # ta.crossover/crossunder necesitan vela anterior

    my $close      = $c->{close};
    my $prev_close = $prev->{close};
    return unless defined $close && defined $prev_close;

    my $confirm_mode = $self->{confirm_mode} // 'close';
    # David/Pine SIEMPRE usa close para crossover. El modo 'wick' es extension
    # de Kevin: confirma con high/low pero sigue exigiendo cruce real.
    my $bull_cur  = ($confirm_mode eq 'wick' && defined $c->{high})    ? $c->{high}    : $close;
    my $bull_prev = ($confirm_mode eq 'wick' && defined $prev->{high}) ? $prev->{high} : $prev_close;
    my $bear_cur  = ($confirm_mode eq 'wick' && defined $c->{low})     ? $c->{low}     : $close;
    my $bear_prev = ($confirm_mode eq 'wick' && defined $prev->{low})  ? $prev->{low}  : $prev_close;

    my $scope     = $o{scope} // 'swing';
    my $trend_ref = $o{trend_ref};
    my $bar_index = $o{bar_index} // $i;

    # ── Cruce BULLISH (crossover) ─────────────────────────────────────────
    my $ph = ${ $o{high_ref} };
    if (defined $ph && defined $ph->{level} && !$ph->{crossed}) {
        my $level = $ph->{level};
        my $crossover = ($bull_prev <= $level) && ($bull_cur > $level);
        if ($crossover) {
            my $kind = ($$trend_ref == _BEARISH) ? 'CHoCH' : 'BOS';
            $$trend_ref    = _BULLISH;
            $ph->{crossed} = 1;

            my $evt = {
                kind        => $kind,
                scope       => $scope,
                direction   => 'bullish',
                index       => $i,
                level       => $level,
                swing_index => $ph->{index},
                swing_high  => 1,
                swing_low   => 0,
            };
            push @{ $self->{events} }, $evt;
            $self->_push_event($i, $evt);
        }
    }

    # ── Cruce BEARISH (crossunder) ────────────────────────────────────────
    my $pl = ${ $o{low_ref} };
    if (defined $pl && defined $pl->{level} && !$pl->{crossed}) {
        my $level = $pl->{level};
        my $crossunder = ($bear_prev >= $level) && ($bear_cur < $level);
        if ($crossunder) {
            my $kind = ($$trend_ref == _BULLISH) ? 'CHoCH' : 'BOS';
            $$trend_ref    = _BEARISH;
            $pl->{crossed} = 1;

            my $evt = {
                kind        => $kind,
                scope       => $scope,
                direction   => 'bearish',
                index       => $i,
                level       => $level,
                swing_index => $pl->{index},
                swing_high  => 0,
                swing_low   => 1,
            };
            push @{ $self->{events} }, $evt;
            $self->_push_event($i, $evt);
        }
    }
}

1;

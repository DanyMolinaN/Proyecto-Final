package Market::Concepts::FVGEngine;

# =============================================================================
# Market::Concepts::FVGEngine
#
# Replica fiel de la logica FVG de Proyecto_David SMC_Structures2
# (script Pine "SMC Structures and FVG" / LudoGH68):
#
#   isBullishFVG = high[i-3] < low[i-1]
#   isBearishFVG = low[i-3]  > high[i-1]
#
# Mitigacion:
#   - PARCIAL: low < top (bull) / high > bottom (bear) → state='mitigated'
#     (sigue vivo, se dibuja en gris; opcionalmente reduce la caja).
#   - TOTAL:   low <= bottom (bull) / high >= top (bear) → state='deleted'
#     (se elimina de active; deja de dibujarse).
#
# Historial: fvg_history_max (default 5) — al superar max+1 se descarta el
# FVG activo mas antiguo (igual que fvgHistoryNbr del Pine).
#
# NO usa max_age: un FVG no mitigado totalmente permanece hasta borrado
# total o hasta caer fuera del limite de historial.
# =============================================================================

use strict;
use warnings;

use constant DEFAULT_FVG_HISTORY_MAX => 5;

sub new {
    my ($class, %args) = @_;
    my $self = {
        gaps            => [],
        active          => [],
        metadata        => {},
        fvg_history_max => $args{fvg_history_max} // DEFAULT_FVG_HISTORY_MAX,
        fvg_reduce      => $args{fvg_reduce}      // 0,
        %args,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{gaps}     = [];
    $self->{active}   = [];
    $self->{metadata} = {};
    return $self;
}

sub calculate {
    my ($self, $market_data, $structure_engine, %args) = @_;
    return {} unless $market_data;

    $self->reset();
    my $total = $market_data->size();
    my $replay_controller = $args{replay_controller};
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit : ($total - 1);

    my $history_max = $args{fvg_history_max} // $self->{fvg_history_max} // DEFAULT_FVG_HISTORY_MAX;
    my $fvg_reduce  = $args{fvg_reduce}      // $self->{fvg_reduce}      // 0;

    my @candles;
    $#candles = $last_index;
    for my $i (0 .. $last_index) {
        $candles[$i] = $market_data->get_candle($i);
    }

    my @all;      # historial completo (incluye deleted)
    my @active;   # vivos (active + mitigated parcial)

    for my $i (3 .. $last_index) {
        my $c0 = $candles[$i];
        my $c1 = $candles[$i - 1];
        my $c3 = $candles[$i - 3];
        next unless $c0 && $c1 && $c3;

        my $high3 = $c3->{high};
        my $low3  = $c3->{low};
        my $high1 = $c1->{high};
        my $low1  = $c1->{low};
        next unless defined $high3 && defined $low3 && defined $high1 && defined $low1;

        # Mitigacion contra low/high de la barra actual (para FVGs ya existentes)
        my $cur_low  = $c0->{low};
        my $cur_high = $c0->{high};
        my @keep;
        for my $f (@active) {
            if (($f->{dir} // '') eq 'bull' || ($f->{type} // '') eq 'bullish') {
                if (defined $cur_low && $cur_low <= $f->{bottom}) {
                    $f->{state}        = 'deleted';
                    $f->{filled}       = 1;
                    $f->{filled_index} = $i;
                    $f->{mitig_at}     = $i;
                    $f->{extend_to}    = $i;
                    $f->{strength}     = 0;
                    next;   # total → sale de active
                }
                if (defined $cur_low && $cur_low < $f->{top}) {
                    $f->{state}    = 'mitigated';
                    $f->{mitig_at} //= $i;
                    $f->{strength} = 0.55;
                    $f->{top} = $cur_low if $fvg_reduce;
                }
            }
            else {
                if (defined $cur_high && $cur_high >= $f->{top}) {
                    $f->{state}        = 'deleted';
                    $f->{filled}       = 1;
                    $f->{filled_index} = $i;
                    $f->{mitig_at}     = $i;
                    $f->{extend_to}    = $i;
                    $f->{strength}     = 0;
                    next;
                }
                if (defined $cur_high && $cur_high > $f->{bottom}) {
                    $f->{state}    = 'mitigated';
                    $f->{mitig_at} //= $i;
                    $f->{strength} = 0.55;
                    $f->{bottom} = $cur_high if $fvg_reduce;
                }
            }
            $f->{extend_to} = $last_index;
            push @keep, $f;
        }
        @active = @keep;

        # Detectar FVG nuevos (después de evaluar mitigacion de FVGs anteriores)
        if ($high3 < $low1) {
            my $fvg = {
                type          => 'bullish',
                dir           => 'bull',
                top           => $low1,
                bottom        => $high3,
                mid_price     => ($low1 + $high3) / 2,
                price         => ($low1 + $high3) / 2,
                size          => abs($low1 - $high3),
                index         => $i - 2,
                created_index => $i,
                idx_start     => $i - 2,
                extend_to     => $last_index,
                state         => 'active',
                filled        => 0,
                filled_index  => undef,
                mitig_at      => undef,
                strength      => 1,
            };
            push @all, $fvg;
            push @active, $fvg;
            _trim_history(\@active, $history_max);
        }
        if ($low3 > $high1) {
            my $fvg = {
                type          => 'bearish',
                dir           => 'bear',
                top           => $low3,
                bottom        => $high1,
                mid_price     => ($low3 + $high1) / 2,
                price         => ($low3 + $high1) / 2,
                size          => abs($low3 - $high1),
                index         => $i - 2,
                created_index => $i,
                idx_start     => $i - 2,
                extend_to     => $last_index,
                state         => 'active',
                filled        => 0,
                filled_index  => undef,
                mitig_at      => undef,
                strength      => 1,
            };
            push @all, $fvg;
            push @active, $fvg;
            _trim_history(\@active, $history_max);
        }
    }

    # Solo se dibujan FVG vivos (active + mitigated parcial). Los deleted
    # quedan en gaps para auditoria pero el overlay filtra por state/filled.
    $self->{gaps}   = \@all;
    $self->{active} = \@active;
    $self->{metadata} = {
        timeframe       => $args{timeframe} || ($market_data->can('active_tf') ? $market_data->active_tf() : undef),
        gap_count       => scalar(@all),
        active_count    => scalar(@active),
        visible_limit   => $visible_limit,
        fvg_history_max => $history_max,
        fvg_reduce      => $fvg_reduce,
        # Sin max_age: compat con overlay legacy (valor alto = no fade prematuro)
        max_age_bars    => $last_index + 1,
    };

    return {
        gaps     => $self->{gaps},
        active   => $self->{active},
        metadata => $self->{metadata},
    };
}

sub _trim_history {
    my ($active, $history_max) = @_;
    $history_max = DEFAULT_FVG_HISTORY_MAX unless defined $history_max;
    while (scalar(@$active) > $history_max + 1) {
        my $oldest = shift @$active;
        $oldest->{state}     = 'deleted';
        $oldest->{filled}    = 1;
        $oldest->{strength}  = 0;
        $oldest->{extend_to} = $oldest->{mitig_at} // $oldest->{created_index};
    }
}

sub gaps   { my ($self) = @_; return $self->{gaps}   || []; }
sub active { my ($self) = @_; return $self->{active} || []; }

1;

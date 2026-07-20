package Market::Indicators::TrendChannel;

use strict;
use warnings;
use Carp;
use Market::Indicators::ZigZagMTF;

# Tolerancia de pendiente para considerar lineas como paralelas (15% diff relativa maxima)
use constant CHANNEL_SLOPE_TOLERANCE => 0.15;
# Tolerancia de barras consecutivas cerrando fuera del canal para invalidarlo
use constant CHANNEL_BREAK_CONFIRMATION_BARS => 3;
# Diferencia maxima absoluta en pendiente para canales casi horizontales
use constant HORIZONTAL_SLOPE_THRESHOLD => 0.0005;
use constant MAX_ACTIVE_CHANNELS => 3;
use constant CHANNEL_LOOKBACK_SWINGS => 12;
use constant INVALIDATED_CHANNEL_RETENTION_BARS => 25;

sub new {
    my ($class, %args) = @_;
    my $self = {
        zigzag            => Market::Indicators::ZigZagMTF->new(),
        last_index        => -1,
        channels          => [],
        # Estado de barras fuera del canal para la deteccion de ruptura
        break_counters    => {}, # channel_id -> { side => 'support'|'resistance', count => N }
        channel_seq       => 0,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{last_index} = -1;
    $self->{channels} = [];
    $self->{break_counters} = {};
    $self->{channel_seq} = 0;
    $self->{zigzag}->reset();
}

sub update_at_index {
    my ($self, $index, $market_data) = @_;
    return unless $market_data && defined $index && $index >= 0;
    $self->sync_to_index($index, $market_data);
}

sub sync_to_index {
    my ($self, $index, $market_data) = @_;
    return unless $market_data && defined $index;
    
    my $last = $self->{last_index};
    $last = -1 unless defined $last;
    return if $index <= $last;

    # Actualizar dependencias
    for my $i ($last + 1 .. $index) {
        $self->{zigzag}->update_at_index($i, $market_data);
    }
    
    # Evaluar canales activos en cada nueva vela para posibles rupturas
    for my $i ($last + 1 .. $index) {
        my $candle = $market_data->get_candle($i);
        next unless $candle;
        
        for my $channel (@{$self->{channels}}) {
            next unless $channel->{state} eq 'active';
            
            # Actualizamos end_index visual
            $channel->{support}{end_index} = $i;
            $channel->{resistance}{end_index} = $i;
            
            # Comprobar ruptura (fakeout tolerance)
            $self->_check_channel_break($channel, $i, $candle);
        }
    }
    
    $self->{last_index} = $index;
}

sub _check_channel_break {
    my ($self, $channel, $index, $candle) = @_;
    my $id = $channel->{id};
    
    my $close = $candle->{close};
    my $m_sup = $channel->{slope_support};
    my $m_res = $channel->{slope_resistance};
    
    my $dx_sup = $index - $channel->{support}{pivot1}{index};
    my $proj_sup = $channel->{support}{pivot1}{price} + $m_sup * $dx_sup;
    
    my $dx_res = $index - $channel->{resistance}{pivot1}{index};
    my $proj_res = $channel->{resistance}{pivot1}{price} + $m_res * $dx_res;
    
    my $is_outside_support = $close < $proj_sup;
    my $is_outside_resistance = $close > $proj_res;
    
    if ($is_outside_support || $is_outside_resistance) {
        $self->{break_counters}{$id} ||= { count => 0, side => undef };
        
        my $current_side = $is_outside_support ? 'support' : 'resistance';
        if (!defined $self->{break_counters}{$id}{side} || $self->{break_counters}{$id}{side} ne $current_side) {
            $self->{break_counters}{$id}{side} = $current_side;
            $self->{break_counters}{$id}{count} = 1;
        } else {
            $self->{break_counters}{$id}{count}++;
        }
        
        if ($self->{break_counters}{$id}{count} >= CHANNEL_BREAK_CONFIRMATION_BARS) {
            $channel->{state} = 'invalidated';
            $channel->{invalidated_at} = $index;
            $channel->{break_side} = $self->{break_counters}{$id}{side};
            $channel->{support}{state} = 'invalidated';
            $channel->{resistance}{state} = 'invalidated';
        }
    } else {
        # Fakeout recuperado (precio vuelve dentro del canal)
        if (exists $self->{break_counters}{$id}) {
            delete $self->{break_counters}{$id};
        }
    }
}

sub calculate {
    my ($self, $market_data, %args) = @_;
    croak "market_data is required" unless $market_data;
    
    my $end_index = $args{end_index};
    $end_index = $market_data->size() - 1 unless defined $end_index;
    
    # Sincronizamos estado
    $self->sync_to_index($end_index, $market_data);
    
    # Reconstruir canales (estrategia simple: buscar sobre ultimos swings)
    my $swings = $args{source_swings};
    if (!$swings || @$swings < 2) {
        my $zz_res = $self->{zigzag}->calculate($market_data, end_index => $end_index);
        $swings = $zz_res->{internal_swings} || $zz_res->{swings} || [];
    }
    
    my %valid_pivots = map { ($_->{index} => 1) }
        grep { ref $_ eq 'HASH' && defined $_->{index} } @$swings;

    my @kept_channels;
    for my $channel (@{ $self->{channels} || [] }) {
        next unless $channel && ref $channel eq 'HASH';
        my @idx = (
            $channel->{support}{pivot1}{index},
            $channel->{support}{pivot2}{index},
            $channel->{resistance}{pivot1}{index},
            $channel->{resistance}{pivot2}{index},
        );
        next if grep { !defined $_ || !$valid_pivots{$_} } @idx;
        if (($channel->{state} || '') eq 'invalidated') {
            next if defined $channel->{invalidated_at}
                && $end_index - $channel->{invalidated_at} > INVALIDATED_CHANNEL_RETENTION_BARS;
        }
        push @kept_channels, $channel;
    }
    $self->{channels} = \@kept_channels;

    # Extraemos Highs y Lows y acotamos a los swings recientes. La decision de
    # diseno es "un canal vigente por region temporal": primero buscamos solo en
    # pivotes cercanos, luego agrupamos candidatos solapados y conservamos el de
    # mas toques; si empatan, gana el que une pivotes mas separados.
    my @highs = grep { $_->{type} eq 'high' } sort { $a->{index} <=> $b->{index} } @$swings;
    my @lows  = grep { $_->{type} eq 'low'  } sort { $a->{index} <=> $b->{index} } @$swings;
    @highs = @highs > CHANNEL_LOOKBACK_SWINGS ? @highs[-CHANNEL_LOOKBACK_SWINGS .. -1] : @highs;
    @lows  = @lows  > CHANNEL_LOOKBACK_SWINGS ? @lows[-CHANNEL_LOOKBACK_SWINGS .. -1]  : @lows;
    
    # Identificar posibles lineas
    my @sup_lines;
    for (my $i = 0; $i < @lows; $i++) {
        for (my $j = $i + 1; $j < @lows; $j++) {
            my $p1 = $lows[$i];
            my $p2 = $lows[$j];
            my $dx = $p2->{index} - $p1->{index};
            next if $dx == 0;
            my $m = ($p2->{price} - $p1->{price}) / $dx;
            push @sup_lines, {
                p1 => $p1,
                p2 => $p2,
                m => $m,
                touches => _count_line_touches(\@lows, $p1, $m),
            };
        }
    }
    
    my @res_lines;
    for (my $i = 0; $i < @highs; $i++) {
        for (my $j = $i + 1; $j < @highs; $j++) {
            my $p1 = $highs[$i];
            my $p2 = $highs[$j];
            my $dx = $p2->{index} - $p1->{index};
            next if $dx == 0;
            my $m = ($p2->{price} - $p1->{price}) / $dx;
            push @res_lines, {
                p1 => $p1,
                p2 => $p2,
                m => $m,
                touches => _count_line_touches(\@highs, $p1, $m),
            };
        }
    }
    
    my @candidates;
    for my $sup (@sup_lines) {
        for my $res (@res_lines) {
            # Deben superponerse en el tiempo para tener sentido
            my $sup_start = $sup->{p1}{index};
            my $res_start = $res->{p1}{index};
            my $sup_end = $sup->{p2}{index};
            my $res_end = $res->{p2}{index};
            
            my $overlap_start = $sup_start > $res_start ? $sup_start : $res_start;
            my $overlap_end   = $sup_end < $res_end ? $sup_end : $res_end;
            
            next if $overlap_start > $overlap_end; # No comparten tiempo
            
            # Verificar paralelismo
            my $m1 = $sup->{m};
            my $m2 = $res->{m};
            
            my $avg_m = ($m1 + $m2) / 2;
            my $diff = abs($m1 - $m2);
            my $rel_diff = abs($avg_m) > 1e-6 ? $diff / abs($avg_m) : $diff;
            
            if ($rel_diff <= CHANNEL_SLOPE_TOLERANCE || $diff < HORIZONTAL_SLOPE_THRESHOLD) {
                # Es un canal paralelo valido
                my $type = 'horizontal';
                if ($avg_m > HORIZONTAL_SLOPE_THRESHOLD) {
                    $type = 'ascending';
                } elsif ($avg_m < -HORIZONTAL_SLOPE_THRESHOLD) {
                    $type = 'descending';
                }
                
                # Resistencia debe estar estrictamente POR ENCIMA del soporte
                my $test_idx = $overlap_start;
                my $p_sup = $sup->{p1}{price} + $m1 * ($test_idx - $sup->{p1}{index});
                my $p_res = $res->{p1}{price} + $m2 * ($test_idx - $res->{p1}{index});
                
                next if $p_sup >= $p_res; # Canal invertido invalido
                
                push @candidates, {
                    type => $type,
                    support => $sup,
                    resistance => $res,
                    start_index => $overlap_start,
                    end_index => $overlap_end,
                    score => ($sup->{touches} || 0) + ($res->{touches} || 0),
                    span => _max($sup->{p2}{index}, $res->{p2}{index})
                          - _min($sup->{p1}{index}, $res->{p1}{index}),
                };
            }
        }
    }

    my @best_candidates = _best_channel_candidates(@candidates);
    my %seen = map { (_channel_key($_) => 1) } @{ $self->{channels} || [] };
    for my $cand (@best_candidates) {
        last if scalar(@{ $self->{channels} || [] }) >= MAX_ACTIVE_CHANNELS;
        my $key = join ':',
            $cand->{support}{p1}{index}, $cand->{support}{p2}{index},
            $cand->{resistance}{p1}{index}, $cand->{resistance}{p2}{index};
        next if $seen{$key};
        my $new_ch = $self->_new_channel_from_candidate($cand, $end_index);
        push @{ $self->{channels} }, $new_ch;
        $seen{$key} = 1;
    }

    my @ranked = sort {
        (($b->{state} || '') eq 'active') <=> (($a->{state} || '') eq 'active')
        || (($b->{touches_support} || 0) + ($b->{touches_resistance} || 0))
            <=> (($a->{touches_support} || 0) + ($a->{touches_resistance} || 0))
        || _channel_recent_index($b) <=> _channel_recent_index($a)
    } @{ $self->{channels} || [] };
    @ranked = @ranked[0 .. MAX_ACTIVE_CHANNELS - 1] if @ranked > MAX_ACTIVE_CHANNELS;
    $self->{channels} = \@ranked;

    return { channels => $self->{channels} };
}

sub _new_channel_from_candidate {
    my ($self, $cand, $end_index) = @_;
    my $sup = $cand->{support};
    my $res = $cand->{resistance};
    $self->{channel_seq}++;
    my $new_ch = {
        id => $self->{channel_seq},
        type => $cand->{type},
        support => {
            pivot1 => { index => $sup->{p1}{index}, price => $sup->{p1}{price} },
            pivot2 => { index => $sup->{p2}{index}, price => $sup->{p2}{price} },
            end_index => $end_index,
            state => 'active'
        },
        resistance => {
            pivot1 => { index => $res->{p1}{index}, price => $res->{p1}{price} },
            pivot2 => { index => $res->{p2}{index}, price => $res->{p2}{price} },
            end_index => $end_index,
            state => 'active'
        },
        slope_support => $sup->{m},
        slope_resistance => $res->{m},
        touches_support => $sup->{touches},
        touches_resistance => $res->{touches},
        state => 'active',
        invalidated_at => undef,
        break_side => undef,
    };
    $new_ch->{midline_at} = sub {
        my $idx = shift;
        my $s = $new_ch->{support}{pivot1}{price} + $new_ch->{slope_support} * ($idx - $new_ch->{support}{pivot1}{index});
        my $r = $new_ch->{resistance}{pivot1}{price} + $new_ch->{slope_resistance} * ($idx - $new_ch->{resistance}{pivot1}{index});
        return ($s + $r) / 2;
    };
    return $new_ch;
}

sub _best_channel_candidates {
    my @sorted = sort {
        ($b->{score} || 0) <=> ($a->{score} || 0)
        || ($b->{span} || 0) <=> ($a->{span} || 0)
        || ($b->{end_index} || 0) <=> ($a->{end_index} || 0)
    } @_;
    my @chosen;
    CANDIDATE:
    for my $cand (@sorted) {
        for my $kept (@chosen) {
            next CANDIDATE if _overlap_ratio(
                $cand->{start_index}, $cand->{end_index},
                $kept->{start_index}, $kept->{end_index},
            ) > 0.50;
        }
        push @chosen, $cand;
        last if @chosen >= MAX_ACTIVE_CHANNELS;
    }
    return @chosen;
}

sub _count_line_touches {
    my ($swings, $p1, $m) = @_;
    return 0 unless $swings && $p1;
    my @prices = grep { defined $_ } map { $_->{price} } @$swings;
    return 2 unless @prices;
    my ($min, $max) = ($prices[0], $prices[0]);
    for my $p (@prices) {
        $min = $p if $p < $min;
        $max = $p if $p > $max;
    }
    my $tol = ($max - $min) * 0.02;
    $tol = 0.000001 if $tol <= 0;
    my $touches = 0;
    for my $sw (@$swings) {
        next unless defined $sw->{index} && defined $sw->{price};
        my $projected = $p1->{price} + $m * ($sw->{index} - $p1->{index});
        $touches++ if abs($sw->{price} - $projected) <= $tol;
    }
    return $touches;
}

sub _overlap_ratio {
    my ($a1, $a2, $b1, $b2) = @_;
    return 0 unless defined $a1 && defined $a2 && defined $b1 && defined $b2;
    my $start = _max($a1, $b1);
    my $end = _min($a2, $b2);
    return 0 if $end < $start;
    my $overlap = $end - $start + 1;
    my $shorter = _min($a2 - $a1 + 1, $b2 - $b1 + 1);
    return 0 if $shorter <= 0;
    return $overlap / $shorter;
}

sub _channel_key {
    my ($c) = @_;
    return join ':',
        $c->{support}{pivot1}{index}, $c->{support}{pivot2}{index},
        $c->{resistance}{pivot1}{index}, $c->{resistance}{pivot2}{index};
}

sub _channel_recent_index {
    my ($c) = @_;
    return _max(
        $c->{support}{pivot2}{index} || 0,
        $c->{resistance}{pivot2}{index} || 0,
    );
}

sub _min { $_[0] < $_[1] ? $_[0] : $_[1] }
sub _max { $_[0] > $_[1] ? $_[0] : $_[1] }

1;

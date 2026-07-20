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
    
    # Extraemos Highs y Lows
    my @highs = grep { $_->{type} eq 'high' } @$swings;
    my @lows  = grep { $_->{type} eq 'low' } @$swings;
    
    # Identificar posibles lineas
    my @sup_lines;
    for (my $i = 0; $i < @lows; $i++) {
        for (my $j = $i + 1; $j < @lows; $j++) {
            my $p1 = $lows[$i];
            my $p2 = $lows[$j];
            my $dx = $p2->{index} - $p1->{index};
            next if $dx == 0;
            my $m = ($p2->{price} - $p1->{price}) / $dx;
            push @sup_lines, { p1 => $p1, p2 => $p2, m => $m, touches => 2 };
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
            push @res_lines, { p1 => $p1, p2 => $p2, m => $m, touches => 2 };
        }
    }
    
    # Encontrar emparejamientos validos (Canales)
    # Por simplicidad en esta implementacion reconstruimos y filtramos canales existentes
    # o creamos nuevos si no solapan excesivamente
    my @detected_channels;
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
                
                # Buscamos si ya existe en self->channels para mantener su estado
                my $existing;
                for my $c (@{$self->{channels}}) {
                    if ($c->{support}{pivot1}{index} == $sup->{p1}{index} &&
                        $c->{support}{pivot2}{index} == $sup->{p2}{index} &&
                        $c->{resistance}{pivot1}{index} == $res->{p1}{index} &&
                        $c->{resistance}{pivot2}{index} == $res->{p2}{index}) {
                        $existing = $c;
                        last;
                    }
                }
                
                if ($existing) {
                    push @detected_channels, $existing;
                } else {
                    $self->{channel_seq}++;
                    my $new_ch = {
                        id => $self->{channel_seq},
                        type => $type,
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
                        slope_support => $m1,
                        slope_resistance => $m2,
                        touches_support => $sup->{touches},
                        touches_resistance => $res->{touches},
                        state => 'active',
                        invalidated_at => undef,
                        break_side => undef,
                    };
                    
                    # Añadir funcion midline
                    $new_ch->{midline_at} = sub {
                        my $idx = shift;
                        my $s = $new_ch->{support}{pivot1}{price} + $new_ch->{slope_support} * ($idx - $new_ch->{support}{pivot1}{index});
                        my $r = $new_ch->{resistance}{pivot1}{price} + $new_ch->{slope_resistance} * ($idx - $new_ch->{resistance}{pivot1}{index});
                        return ($s + $r) / 2;
                    };
                    
                    push @detected_channels, $new_ch;
                    push @{$self->{channels}}, $new_ch;
                }
            }
        }
    }
    
    # Solo devolvemos los canales procesados
    return { channels => \@detected_channels };
}

1;

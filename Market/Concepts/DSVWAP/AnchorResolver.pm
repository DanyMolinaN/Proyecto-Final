package Market::Concepts::DSVWAP::AnchorResolver;

use strict;
use warnings;
use List::Util qw(max min);
use Market::Concepts::DSVWAP::Event;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::AnchorResolver
# Responsabilidad: Decidir cuál es el Anchor válido.
# Escucha los swings (regulares o ticks para el ghost) y mantiene la
# máquina de estado de seguimiento (máximos y mínimos intermedios)
# para emitir AnchorChangedEvent.
# =============================================================================

sub new {
    my ($class, $event_bus, $length, $show_miss, $cache) = @_;
    my $self = {
        bus        => $event_bus,
        length     => $length || 50,
        show_miss  => $show_miss // 1,
        cache      => $cache,
    };
    
    bless $self, $class;
    
    # Registro de handlers
    $self->{bus}->subscribe('NewBarEvent', sub { $self->_on_new_bar(@_) });
    $self->{bus}->subscribe('SwingConfirmedEvent', sub { $self->_on_swing_confirmed(@_) });
    
    $self->reset();
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{os}            = 0;
    $self->{px1}           = 0;
    $self->{py1}           = 0.0;
    
    $self->{max_v}         = 0.0;
    $self->{min_v}         = 0.0;
    $self->{max_x1}        = 0;
    $self->{min_x1}        = 0;
    
    $self->{follow_max}    = 0.0;
    $self->{follow_min}    = 0.0;
    $self->{follow_max_x1} = 0;
    $self->{follow_min_x1} = 0;
}

sub _on_new_bar {
    my ($self, $event) = @_;
    my $index       = $event->{index};
    my $market_data = $event->{bar}; # Ref to MarketData full object
    
    my $len = $self->{length};
    my $i_len = $index - $len;
    return if $i_len < 0;

    my $c_len = $market_data->get_candle($i_len);
    return unless $c_len;
    my $high_len = $c_len->{high};
    my $low_len  = $c_len->{low};

    # Simular la recoleccion del max y min desfasado
    my $prev_max = $self->{max_v};
    my $prev_min = $self->{min_v};
    my $prev_f_max = $self->{follow_max};
    my $prev_f_min = $self->{follow_min};

    if (!defined $self->{init_flag}) {
        $self->{max_v} = $high_len;
        $self->{min_v} = $low_len;
        $self->{follow_max} = $high_len;
        $self->{follow_min} = $low_len;
        $self->{init_flag} = 1;
    }

    if ($high_len > $self->{max_v}) {
        $self->{max_v} = $high_len;
    }
    if ($low_len < $self->{min_v}) {
        $self->{min_v} = $low_len;
    }
    if ($high_len > $self->{follow_max}) {
        $self->{follow_max} = $high_len;
    }
    if ($low_len < $self->{follow_min}) {
        $self->{follow_min} = $low_len;
    }

    if ($self->{max_v} > $prev_max) {
        $self->{max_x1} = $i_len;
        $self->{follow_min} = $low_len;
    }
    if ($self->{min_v} < $prev_min) {
        $self->{min_x1} = $i_len;
        $self->{follow_max} = $high_len;
    }
    if ($self->{follow_min} < $prev_f_min) {
        $self->{follow_min_x1} = $i_len;
    }
    if ($self->{follow_max} > $prev_f_max) {
        $self->{follow_max_x1} = $i_len;
    }
}

sub _on_swing_confirmed {
    my ($self, $event) = @_;
    my $c_index   = $event->{index};
    my $price     = $event->{price};
    my $direction = $event->{direction}; # -1 High, 1 Low

    my $c = $self->{cache};

    if ($direction == -1) { # Pivot High
        if ($self->{show_miss}) {
            if ($self->{os} == 1) {
                $self->_emit_ghost(1, $self->{min_x1}, $self->{min_v});
            } elsif ($price < $self->{max_v}) {
                $self->_emit_ghost(-1, $self->{max_x1}, $self->{max_v});
                $self->_emit_ghost(1, $self->{follow_min_x1}, $self->{follow_min});
            }
        }
        $self->_emit_regular(-1, $c_index, $price);

        $self->{py1} = $price;
        $self->{px1} = $c_index;
        $self->{os}  = 1;
        $self->{max_v} = $price;
        $self->{min_v} = $price;

    } elsif ($direction == 1) { # Pivot Low
        if ($self->{show_miss}) {
            if ($self->{os} == 0) {
                $self->_emit_ghost(-1, $self->{max_x1}, $self->{max_v});
            } elsif ($price > $self->{min_v}) {
                $self->_emit_ghost(1, $self->{min_x1}, $self->{min_v});
                $self->_emit_ghost(-1, $self->{follow_max_x1}, $self->{follow_max});
            }
        }
        $self->_emit_regular(1, $c_index, $price);

        $self->{py1} = $price;
        $self->{px1} = $c_index;
        $self->{os}  = 0;
        $self->{max_v} = $price;
        $self->{min_v} = $price;
    }
}

sub _emit_ghost {
    my ($self, $dir, $index, $price) = @_;
    # Cacheamos el segmento de línea
    push @{$self->{cache}{zigzag_lines}}, {
        x1 => $self->{px1}, y1 => $self->{py1},
        x2 => $index, y2 => $price,
        is_ghost => 1, dir => $dir
    };
    push @{$self->{cache}{ghost_levels}}, { x => $index, y => $price };
    
    $self->{px1} = $index;
    $self->{py1} = $price;

    $self->{bus}->dispatch(
        Market::Concepts::DSVWAP::Event->anchor_changed($index, $price, $dir)
    );
}

sub _emit_regular {
    my ($self, $dir, $index, $price) = @_;
    push @{$self->{cache}{zigzag_lines}}, {
        x1 => $self->{px1}, y1 => $self->{py1},
        x2 => $index, y2 => $price,
        is_ghost => 0, dir => $dir
    };
    
    $self->{bus}->dispatch(
        Market::Concepts::DSVWAP::Event->anchor_changed($index, $price, $dir)
    );
}

1;

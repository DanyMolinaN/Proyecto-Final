package Market::Concepts::DSVWAP::GhostEngine;

use strict;
use warnings;
use List::Util qw(max min);

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::GhostEngine
# Responsabilidad: Generar el "Live Preview" (VWAP flotante temporal)
# No contamina los acumuladores principales. Se procesa solo en la
# última barra de la serie actual del chart.
# =============================================================================

sub new {
    my ($class, $event_bus, $cache, $price_source, $show_miss) = @_;
    my $self = {
        bus          => $event_bus,
        cache        => $cache,
        price_source => $price_source || 'HLC3',
        show_miss    => $show_miss // 1,
    };
    
    bless $self, $class;
    
    # Nos suscribimos al final del procesamiento de barras para revisar si es la última
    $self->{bus}->subscribe('NewBarEvent', sub { $self->_on_new_bar(@_) });
    
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{cache}->clear_ghost();
}

sub _on_new_bar {
    my ($self, $event) = @_;
    my $is_last = $event->{is_last};
    
    # Sólo procesamos el fantasma en el extremo del mercado
    return unless $is_last;

    my $index       = $event->{index};
    my $market_data = $event->{bar};

    $self->{cache}->clear_ghost();
    return unless $self->{show_miss};

    # Extraemos el último px1 y os registrados del AnchorResolver a través del historial, 
    # pero como necesitamos evitar dependencias circulares, leeremos el último zigzag del cache
    my $lines = $self->{cache}{zigzag_lines};
    return unless @$lines > 0;
    
    my $last_line = $lines->[-1];
    my $px1 = $last_line->{x2};
    my $os  = $last_line->{dir} == -1 ? 1 : 0; # Si el ultimo ancla fue High (-1), estamos buscando Low (os=1)

    return if $index - $px1 <= 0; # Prevenir errores si el ancla es la propia vela actual

    # Buscar min/max desde px1 hasta la actual
    my $x_last = 0;
    my $y_last = 0.0;
    
    if ($os == 1) { # Buscando Low
        my $c_init = $market_data->get_candle($px1 + 1);
        $y_last = $c_init ? $c_init->{low} : 0;
        $x_last = $px1 + 1;
        for (my $i = $px1 + 2; $i <= $index; $i++) {
            my $c = $market_data->get_candle($i);
            next unless $c;
            if ($c->{low} < $y_last) {
                $y_last = $c->{low};
                $x_last = $i;
            }
        }
    } else { # Buscando High
        my $c_init = $market_data->get_candle($px1 + 1);
        $y_last = $c_init ? $c_init->{high} : 0;
        $x_last = $px1 + 1;
        for (my $i = $px1 + 2; $i <= $index; $i++) {
            my $c = $market_data->get_candle($i);
            next unless $c;
            if ($c->{high} > $y_last) {
                $y_last = $c->{high};
                $x_last = $i;
            }
        }
    }

    # Guardar rastro visual efímero
    my $dir = $os == 1 ? 1 : -1;
    $self->{cache}{ghost_line} = { x1 => $px1, y1 => $last_line->{y2}, x2 => $x_last, y2 => $y_last, dir => $dir };
    $self->{cache}{ghost_label} = { x => $x_last, y => $y_last, dir => $dir };

    # Calcular VWAP Fantasma desde $x_last
    my $g_cum_vol  = 0.0;
    my $g_cum_pvol = 0.0;
    my $g_sum_sq   = 0.0;
    my $g_last_vwap = 0.0;

    for (my $i = $x_last; $i <= $index; $i++) {
        my $c = $market_data->get_candle($i);
        next unless $c;
        my $src = $self->_get_src_price($c);
        my $vol = $c->{volume} || 0;
        next if $vol == 0;

        $g_cum_vol  += $vol;
        $g_cum_pvol += $src * $vol;
        my $g_vwap   = $g_cum_pvol / $g_cum_vol;

        $g_sum_sq += $vol * ($src - $g_last_vwap) * ($src - $g_vwap);
        $g_last_vwap = $g_vwap;

        my $g_std_dev = sqrt($g_sum_sq / $g_cum_vol);

        push @{$self->{cache}{ghost_vwap}},     { x => $i, y => $g_vwap, dir => $dir };
        push @{$self->{cache}{ghost_bands_u1}}, { x => $i, y => $g_vwap + $g_std_dev };
        push @{$self->{cache}{ghost_bands_l1}}, { x => $i, y => $g_vwap - $g_std_dev };
        push @{$self->{cache}{ghost_bands_u2}}, { x => $i, y => $g_vwap + 2*$g_std_dev };
        push @{$self->{cache}{ghost_bands_l2}}, { x => $i, y => $g_vwap - 2*$g_std_dev };
        push @{$self->{cache}{ghost_bands_u3}}, { x => $i, y => $g_vwap + 3*$g_std_dev };
        push @{$self->{cache}{ghost_bands_l3}}, { x => $i, y => $g_vwap - 3*$g_std_dev };
    }
}

sub _get_src_price {
    my ($self, $candle) = @_;
    my $src_type = $self->{price_source};
    
    if ($src_type eq 'Close') {
        return $candle->{close};
    } elsif ($src_type eq 'OC2') {
        return ($candle->{open} + $candle->{close}) / 2;
    } elsif ($src_type eq 'OHLC4') {
        return ($candle->{open} + $candle->{high} + $candle->{low} + $candle->{close}) / 4;
    } else {
        return ($candle->{high} + $candle->{low} + $candle->{close}) / 3;
    }
}

1;

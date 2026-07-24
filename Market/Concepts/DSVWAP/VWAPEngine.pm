package Market::Concepts::DSVWAP::VWAPEngine;

use strict;
use warnings;
use Market::Concepts::DSVWAP::Event;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::VWAPEngine
# Responsabilidad: Calcular el VWAP y sus bandas incrementalmente en O(1).
# Algoritmo: Welford para varianza en un paso, evitando iterar historiales.
# Emite: VWAPResetEvent y VWAPAccumulatedEvent
# =============================================================================

sub new {
    my ($class, $event_bus, $cache, $price_source) = @_;
    my $self = {
        bus          => $event_bus,
        cache        => $cache,
        price_source => $price_source || 'HLC3',
        
        # Estado acumulativo
        anchor_x     => undef,
        current_dir  => 0,
        cum_vol      => 0.0,
        cum_pvol     => 0.0,
        sum_sq_diff  => 0.0,
        last_vwap    => 0.0,
    };
    
    bless $self, $class;
    
    $self->{bus}->subscribe('AnchorChangedEvent', sub { $self->_on_anchor_changed(@_) });
    
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{anchor_x}    = undef;
    $self->{current_dir} = 0;
    $self->{cum_vol}     = 0.0;
    $self->{cum_pvol}    = 0.0;
    $self->{sum_sq_diff} = 0.0;
    $self->{last_vwap}   = 0.0;
    $self->{cache}->clear_main_vwap();
}

sub _on_anchor_changed {
    my ($self, $event) = @_;
    # Cuando cambia el ancla, NO reseteamos aquí mismo los acumuladores,
    # porque el evento nos da el índice del pivot pasado.
    # En un modelo incremental estricto sin mirar al pasado, necesitamos reconstruir
    # desde el anchor_x hasta la barra actual, O pedir al registry que nos
    # entregue ese segmento.
    
    # Dado que el Ghost puede emitirse "después" y retroceder el ancla,
    # es matemáticamente ineludible reprocesar el segmento desde el ancla hasta el índice actual (b).
    # Sin embargo, como el Engine principal nos llamará para procesar esta barra en breve,
    # guardamos la solicitud de "re-anclaje".
    $self->{pending_reanchor} = {
        x   => $event->{index},
        dir => $event->{direction}
    };
}

# process_bar se llama desde el Engine principal por CADA barra.
sub process_bar {
    my ($self, $market_data, $index) = @_;

    # Si hubo un cambio de ancla, reprocesamos en modo "catch-up" desde el ancla hasta hoy.
    # Esto ocurre porque el AnchorResolver descubrió el pivot N barras atrás.
    if ($self->{pending_reanchor}) {
        my $anchor_idx = $self->{pending_reanchor}{x};
        $self->{current_dir} = $self->{pending_reanchor}{dir};
        $self->{anchor_x} = $anchor_idx;
        $self->{pending_reanchor} = undef;

        $self->{cum_vol} = 0.0;
        $self->{cum_pvol} = 0.0;
        $self->{sum_sq_diff} = 0.0;
        $self->{last_vwap} = 0.0;
        $self->{cache}->clear_main_vwap();

        # Catch-up (re-acumulación rápida desde el ancla)
        for (my $i = $anchor_idx; $i <= $index; $i++) {
            $self->_accumulate_bar($market_data, $i);
        }
    } 
    elsif (defined $self->{anchor_x}) {
        # Flujo normal O(1)
        $self->_accumulate_bar($market_data, $index);
    }
}

sub _accumulate_bar {
    my ($self, $market_data, $idx) = @_;
    my $c = $market_data->get_candle($idx);
    return unless $c;
    my $src = $self->_get_src_price($c);
    my $vol = $c->{volume} || 0;
    
    return if $vol == 0;

    # Welford para suma de varianzas ponderadas:
    # 1. Update means
    $self->{cum_vol}  += $vol;
    $self->{cum_pvol} += $src * $vol;
    my $vwap = $self->{cum_pvol} / $self->{cum_vol};

    # 2. Update sum of squared differences
    # formula incremental: M2 = M2 + w * (x - mean_old) * (x - mean_new)
    $self->{sum_sq_diff} += $vol * ($src - $self->{last_vwap}) * ($src - $vwap);
    $self->{last_vwap} = $vwap;

    my $std_dev = sqrt($self->{sum_sq_diff} / $self->{cum_vol});

    # Guardar directo al caché para el overlay
    push @{$self->{cache}{main_vwap}},     { x => $idx, y => $vwap, dir => $self->{current_dir} };
    push @{$self->{cache}{main_bands_u1}}, { x => $idx, y => $vwap + $std_dev };
    push @{$self->{cache}{main_bands_l1}}, { x => $idx, y => $vwap - $std_dev };
    push @{$self->{cache}{main_bands_u2}}, { x => $idx, y => $vwap + 2*$std_dev };
    push @{$self->{cache}{main_bands_l2}}, { x => $idx, y => $vwap - 2*$std_dev };
    push @{$self->{cache}{main_bands_u3}}, { x => $idx, y => $vwap + 3*$std_dev };
    push @{$self->{cache}{main_bands_l3}}, { x => $idx, y => $vwap - 3*$std_dev };

    $self->{bus}->dispatch(
        Market::Concepts::DSVWAP::Event->vwap_accumulated($idx, $vwap, $std_dev)
    );
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
        # Default HLC3
        return ($candle->{high} + $candle->{low} + $candle->{close}) / 3;
    }
}

1;

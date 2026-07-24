package Market::Concepts::DSVWAP::Event;

use strict;
use warnings;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::Event
# Responsabilidad: Define la estructura de todos los eventos del DSVWAP.
# Cada evento es un simple HashRef ligero (DTO inmutable conceptualmente).
#
# Eventos Emitidos / Consumidos:
# - NewBarEvent:           Por cada vela nueva (histórica o en vivo).
# - TickEvent:             Por cada actualización de precio vivo.
# - SwingConfirmedEvent:   Emitido por SwingEngine cuando detecta pivot.
# - GhostPivotEvent:       Emitido por GhostEngine como propuesta temporal.
# - AnchorChangedEvent:    Emitido por AnchorResolver cuando se fija ancla real.
# - GhostAnchorEvent:      Emitido por AnchorResolver para anclas temporales.
# - VWAPResetEvent:        Emitido por VWAPEngine cuando empieza nueva curva.
# - VWAPAccumulatedEvent:  Emitido por VWAPEngine por cada acumulación.
# =============================================================================

sub new_bar {
    my ($class, $index, $bar_data, $is_last) = @_;
    return {
        type     => 'NewBarEvent',
        index    => $index,
        bar      => $bar_data,
        is_last  => $is_last || 0,
    };
}

sub swing_confirmed {
    my ($class, $index, $price, $direction) = @_;
    return {
        type      => 'SwingConfirmedEvent',
        index     => $index,
        price     => $price,
        direction => $direction, # 1 para Low, -1 para High
    };
}

sub ghost_pivot {
    my ($class, $index, $price, $direction) = @_;
    return {
        type      => 'GhostPivotEvent',
        index     => $index,
        price     => $price,
        direction => $direction,
    };
}

sub anchor_changed {
    my ($class, $index, $price, $direction) = @_;
    return {
        type      => 'AnchorChangedEvent',
        index     => $index,
        price     => $price,
        direction => $direction,
    };
}

sub ghost_anchor {
    my ($class, $index, $price, $direction) = @_;
    return {
        type      => 'GhostAnchorEvent',
        index     => $index,
        price     => $price,
        direction => $direction,
    };
}

sub vwap_accumulated {
    my ($class, $index, $vwap, $std_dev) = @_;
    return {
        type    => 'VWAPAccumulatedEvent',
        index   => $index,
        vwap    => $vwap,
        std_dev => $std_dev,
    };
}

sub vwap_reset {
    my ($class, $index, $vwap) = @_;
    return {
        type  => 'VWAPResetEvent',
        index => $index,
        vwap  => $vwap,
    };
}

sub ghost_vwap_accumulated {
    my ($class, $index, $vwap, $std_dev) = @_;
    return {
        type    => 'GhostVWAPAccumulatedEvent',
        index   => $index,
        vwap    => $vwap,
        std_dev => $std_dev,
    };
}

1;

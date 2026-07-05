package Market::Indicators::ATR;

# =============================================================================
# Market::Indicators::ATR
# -----------------------------------------------------------------------------
# Indicador Average True Range (ATR) con suavizado de Wilder.
# Mide la volatilidad a partir del True Range de cada vela.
#
#   TR  = max( high-low, |high-close_prev|, |low-close_prev| )
#
# Primera vela (sin close previo): TR = high - low. Esto replica exactamente
# `ta.tr(true)` de TradingView, que define el TR de la primera barra como su
# rango high-low. Incluir esta primera barra es CLAVE para que el primer ATR
# quede alineado con la vela (period - 1) y para que coincida con TradingView.
#
# Fase 1 – Bootstrap (primeras `period` velas, indices 0..period-1):
#   Acumula los TR y, al completar el periodo, calcula el primer ATR como
#   la media simple (SMA) de esos TR. Equivale a la semilla SMA de `ta.rma`.
#   El primer valor de la serie corresponde a la vela de indice (period - 1).
#
# Fase 2 – Suavizado de Wilder (velas posteriores):
#   ATR_n = (ATR_{n-1} * (period - 1) + TR) / period
#
# Sin lookahead: cada ATR usa unicamente el TR de su propia vela y los
# anteriores; nunca datos de velas futuras.
#
# Indicador desacoplado: no conoce el chart ni el render, solo calcula su
# serie de valores.
# =============================================================================

use strict;
use warnings;

# new($period) -> $self
# Inicializa el ATR con su periodo (por defecto 14) y serie de valores vacia.
sub new {
    my ($class, $period) = @_;
    my $self = {
        period   => $period || 14,
        values   => [],
        _tr_buf  => [],    # Buffer de TR para el bootstrap SMA inicial
    };
    bless $self, $class;
    return $self;
}

# update_last($market_data)
# Calculo incremental: agrega el TR/ATR de la ULTIMA vela de la temporalidad
# activa. Para la primera vela (size == 1) usa TR = high - low (sin close
# previo), igual que ta.tr(true) de TradingView, de modo que la serie incluya
# la barra 0 y quede correctamente alineada.
sub update_last {
    my ($self, $market_data) = @_;
    my $size = $market_data->size();
    return if $size < 1;

    my $current  = $market_data->get_candle($size - 1);
    my $previous = $size >= 2 ? $market_data->get_candle($size - 2) : undef;
    $self->_push_tr($current, $previous);
}

# recompute($market_data)
# Recalcula toda la serie del ATR sobre las velas de la temporalidad activa,
# comenzando en la vela 0 (cuyo TR = high - low). Necesario al cambiar de
# temporalidad (1m -> 5m -> 15m -> 1H -> 4H -> 1D).
sub recompute {
    my ($self, $market_data) = @_;
    $self->reset();
    my $size = $market_data->size();
    return if $size < 1;

    for my $i (0 .. $size - 1) {
        my $previous = $i >= 1 ? $market_data->get_candle($i - 1) : undef;
        $self->_push_tr($market_data->get_candle($i), $previous);
    }
}

# _push_tr($current, $previous)
# Calcula el True Range de $current y agrega el nuevo valor de ATR a la serie.
# Si no hay vela previa (primera vela), TR = high - low. Usa SMA para el primer
# valor (bootstrap) y Wilder para el resto. Logica compartida por update_last
# y recompute, garantizando resultados identicos por ambas vias.
sub _push_tr {
    my ($self, $current, $previous) = @_;
    return unless $current;

    my $tr;
    if ($previous) {
        my $high_low   = $current->{high} - $current->{low};
        my $high_close = abs($current->{high} - $previous->{close});
        my $low_close  = abs($current->{low}  - $previous->{close});

        $tr = $high_low;
        $tr = $high_close if $high_close > $tr;
        $tr = $low_close  if $low_close  > $tr;
    }
    else {
        # Primera vela: sin close previo. TR = high - low (== ta.tr(true)).
        $tr = $current->{high} - $current->{low};
    }

    my $values  = $self->{values};
    my $tr_buf  = $self->{_tr_buf};
    my $period  = $self->{period};

    # --- FASE 1: Bootstrap SMA ---
    # Acumula TR hasta completar `period` muestras; el primer ATR es su media.
    # Esto replica el calculo de TradingView y da una base estadistica solida.
    if (!@$values) {
        push @$tr_buf, $tr;
        if (scalar @$tr_buf >= $period) {
            my $sum = 0;
            $sum += $_ for @$tr_buf;
            push @$values, $sum / $period;
            @$tr_buf = ();    # Libera el buffer; ya no se necesita.
        }
        return;
    }

    # --- FASE 2: Suavizado de Wilder ---
    my $prev_atr = $values->[-1];
    my $atr = (($prev_atr * ($period - 1)) + $tr) / $period;
    push @$values, $atr;
}

# get_values() -> \@values
# Devuelve la serie completa de valores del ATR.
sub get_values {
    my ($self) = @_;
    return $self->{values};
}

# get_offset() -> $n
# Desfase de la serie respecto al array de velas: el primer valor del ATR
# (values[0]) corresponde a la vela de indice (period - 1). Como ahora la serie
# incluye el TR de la vela 0, este offset queda EXACTO (sin desfase de 1 barra
# ni lookahead): values[k] corresponde a la vela (period - 1 + k).
sub get_offset {
    my ($self) = @_;
    return $self->{period} - 1;
}

# reset()
# Reinicia el indicador (vacia la serie de valores y el buffer de bootstrap).
sub reset {
    my ($self) = @_;
    $self->{values}  = [];
    $self->{_tr_buf} = [];
}

1;

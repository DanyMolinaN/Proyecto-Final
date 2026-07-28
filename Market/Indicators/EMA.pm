package Market::Indicators::EMA;

# =============================================================================
# Market::Indicators::EMA
# Exponential Moving Average (standard EMA, seed via SMA)
#
# Interfaz IDENTICA a Market::Indicators::ATR para consistencia arquitectonica:
#   new($period, %opts)         -- opts: field => 'close' | 'volume' | etc.
#   update_at_index($md, $idx)  -- procesa la vela en $idx (rebuild completo)
#   update_last($md)            -- procesa la ultima vela (streaming)
#   get_values()                -- devuelve arrayref completo de valores EMA
#   reset()                     -- reinicia el indicador
#
# Logica EMA(N):
#   alpha = 2 / (N + 1)
#   Seed: SMA de los primeros N valores (indices 0..N-1)
#          Para i < N: undef (no hay suficiente historia)
#   Para i >= N-1: ema[i] = value[i] * alpha + ema[i-1] * (1 - alpha)
#          (el seed se aplica en i = N-1 exactamente, usando SMA de los N valores)
#
# EMA(9) con field='volume' es el uso principal (DatasetBuilder, Fase 2).
# =============================================================================

use strict;
use warnings;

# -----------------------------------------------------------------------------
# new($period, %opts)
#   $period : periodo del EMA (default 9)
#   field   : campo de la vela a usar (default 'close'; puede ser 'volume', etc.)
# -----------------------------------------------------------------------------
sub new {
    my ($class, $period, %opts) = @_;
    $period //= 9;
    my $self = {
        period      => $period,
        field       => $opts{field} // 'close',
        values      => [],    # EMA calculado por vela (paralelo a candles)
                              # Los primeros (period-1) indices son undef (seed incompleto)
        _seed_vals  => [],    # valores acumulados para el seed SMA
        _seeded     => 0,     # 1 cuando el seed SMA ya fue calculado
        _last_ema   => undef, # EMA de la vela anterior (para la recursion)
        _alpha      => 2 / ($period + 1),
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# update_last($market_data)
# Procesa la ULTIMA vela del market_data. Uso: streaming.
# -----------------------------------------------------------------------------
sub update_last {
    my ($self, $market_data) = @_;
    my $last = $market_data->last_candle;
    return unless defined $last;
    $self->_process_candle($last);
}

# -----------------------------------------------------------------------------
# update_at_index($market_data_or_series, $idx)
# Procesa la vela en $idx. Uso: rebuild completo.
# Compatible con MarketData y con _TFView (duck-type).
# -----------------------------------------------------------------------------
sub update_at_index {
    my ($self, $market_data, $idx) = @_;
    my $candle = $market_data->get_candle($idx);
    return unless defined $candle;
    $self->_process_candle($candle);
}

# -----------------------------------------------------------------------------
# _process_candle (privado)
# Extrae el valor del campo configurado y actualiza el EMA.
# -----------------------------------------------------------------------------
sub _process_candle {
    my ($self, $c) = @_;

    my $field = $self->{field};
    my $value = $c->{$field};

    # Si el campo no existe o es undef, tratamos como 0 con warning.
    unless (defined $value) {
        warn "Market::Indicators::EMA: campo '$field' es undef en la vela, usando 0.\n";
        $value = 0;
    }

    my $n     = $self->{period};
    my $alpha = $self->{_alpha};

    push @{ $self->{_seed_vals} }, $value;
    my $count = scalar @{ $self->{_seed_vals} };

    if (!$self->{_seeded}) {
        if ($count < $n) {
            # Todavia no hay suficientes valores para el seed: undef
            push @{ $self->{values} }, undef;
        } else {
            # Exactamente N valores acumulados: calcular seed SMA
            my $sum = 0;
            $sum += $_ for @{ $self->{_seed_vals} };
            my $seed_ema = $sum / $n;
            $self->{_last_ema} = $seed_ema;
            $self->{_seeded}   = 1;
            push @{ $self->{values} }, $seed_ema;
        }
    } else {
        # EMA standard: ema[i] = value * alpha + ema[i-1] * (1 - alpha)
        my $new_ema = $value * $alpha + $self->{_last_ema} * (1 - $alpha);
        $self->{_last_ema} = $new_ema;
        push @{ $self->{values} }, $new_ema;
    }
}

# -----------------------------------------------------------------------------
# get_values()
# Devuelve arrayref completo de valores EMA. Indices < (period-1) son undef.
# -----------------------------------------------------------------------------
sub get_values {
    my ($self) = @_;
    return $self->{values};
}

# -----------------------------------------------------------------------------
# reset()
# Reinicia el indicador (necesario al cambiar de serie o ventana).
# -----------------------------------------------------------------------------
sub reset {
    my ($self) = @_;
    $self->{values}     = [];
    $self->{_seed_vals} = [];
    $self->{_seeded}    = 0;
    $self->{_last_ema}  = undef;
}

1;

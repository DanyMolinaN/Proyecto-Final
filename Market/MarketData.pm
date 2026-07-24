package Market::MarketData;

# =============================================================================
# Market::MarketData
# -----------------------------------------------------------------------------
# Capa de DATOS del sistema. Almacena y gestiona las velas OHLCV por
# temporalidad (1m, 5m, 15m, 1H, 2H, 4H, 1D, 1W), garantizando acceso eficiente
# por indice y la agregacion de temporalidades superiores desde las velas de 1m.
# Responsabilidad unica: gestionar datos de mercado (no calcula ni dibuja).
# =============================================================================

use strict;
use warnings;

# new() -> $self
# Inicializa el almacenamiento de datos OHLC con la temporalidad 1m vacia.
sub new {
    my ($class) = @_;
    my $self = {
        data                  => { "1m" => [] },
        active_tf             => "1m",
        time_anchors          => [],
        _last_ts              => {},    # Ultimo timestamp visto por temporalidad (dedup)
        tz_offset             => 0,     # Offset (segundos) de la zona del mercado vs UTC
        _replay_boundary      => undef, # Timestamp (epoch) limite del modo replay
        _effective_last_index => {},    # Indice maximo visible por TF (cache)
    };
    bless $self, $class;
    return $self;
}

# set_tz_offset($seconds) / get_tz_offset()
# Offset de la zona horaria del mercado/dataset respecto a UTC, en segundos
# (ej. -05:00 -> -18000). Se usa para alinear los buckets de las temporalidades
# diarias/intradia al reloj del mercado (no al de la maquina) y para que las
# horas mostradas coincidan con TradingView.
sub set_tz_offset {
    my ($self, $seconds) = @_;
    return unless defined $seconds;
    $self->{tz_offset} = $seconds + 0;
}

sub get_tz_offset {
    my ($self) = @_;
    return $self->{tz_offset} || 0;
}

# get_data() -> \%data
# Devuelve la estructura completa de datos (hash de temporalidades -> arrays).
sub get_data {
    my ($self) = @_;
    return $self->{data};
}

# add_candle($candle)
# Entrada principal de datos: agrega una vela (hashref OHLCV) a la serie de 1m.
# Descarta velas con timestamp duplicado para evitar corrupcion en build_tf_candles.
sub add_candle {
    my ($self, $candle) = @_;
    return unless $candle && ref $candle eq 'HASH';

    # Validacion de duplicados: si ya existe una vela con el mismo timestamp
    # en 1m, se ignora silenciosamente para no corromper las temporalidades.
    if (defined $candle->{timestamp}) {
        my $ts = $candle->{timestamp};
        if (defined $self->{_last_ts}{"1m"} && $self->{_last_ts}{"1m"} == $ts) {
            return;
        }
        $self->{_last_ts}{"1m"} = $ts;
    }

    push @{ $self->{data}->{"1m"} }, $candle;
}

# Minutos por temporalidad soportada (spec: 1m,5m,15m,1h,2h,4h,D,W).
my %TF_MINUTES = (
    "1m"  => 1,
    "5m"  => 5,
    "15m" => 15,
    "1H"  => 60,
    "2H"  => 120,
    "4H"  => 240,
    "1D"  => 1440,
    "1W"  => 10080,
);

# Orden canonico de temporalidades (de menor a mayor), util para UI y managers.
my @TF_ORDER = qw(1m 5m 15m 1H 2H 4H 1D 1W);

# Desfase (segundos) aplicado al alinear los buckets de cada temporalidad.
# El epoch 0 (1970-01-01) cae en JUEVES; el primer LUNES 00:00 es epoch
# +345600. Para que los buckets semanales (604800 s) caigan en lunes 00:00 del
# reloj del mercado (estilo TradingView), se aplica un desfase de 3 dias
# (259200 s): asi key*604800 - phase coincide con los lunes.
my %TF_PHASE = (
    "1W" => 3 * 24 * 3600,
);

sub tf_minutes {
    my ($class_or_self, $tf) = @_;
    return $TF_MINUTES{$tf};
}

# tf_order() -> @list  (temporalidades soportadas en orden ascendente)
sub tf_order {
    return @TF_ORDER;
}

# build_tf_candles($tf)
# Construye las velas de una temporalidad superior agregando las velas de 1m.
# Cada vela agregada agrupa las velas de 1m que caen en el mismo intervalo de
# tiempo alineado al reloj (ej: 5m -> :00, :05, :10 ...):
#   open  = apertura de la primera vela del intervalo
#   high  = maximo de los high
#   low   = minimo de los low
#   close = cierre de la ultima vela del intervalo
#   volume= suma de volumenes
sub build_tf_candles {
    my ($self, $tf) = @_;
    return unless defined $tf;

    my $minutes = $TF_MINUTES{$tf};
    unless ($minutes) {
        warn "Temporalidad no soportada: $tf";
        return;
    }

    my $base  = $self->{data}->{"1m"} || [];
    my $secs  = $minutes * 60;
    my $tz    = $self->{tz_offset} || 0;
    my $phase = $TF_PHASE{$tf} || 0;

    my @out;
    my $bucket;
    my $bucket_key;

    for my $c (@$base) {
        next unless $c && defined $c->{timestamp};
        # Alinear el bucket al reloj del MERCADO: se desplaza el epoch por el
        # offset de zona (y un desfase opcional por TF, p.ej. lunes en semanal)
        # antes de agrupar, de modo que los limites caigan en 00:00 / 04:00 /
        # lunes 00:00, etc. de la hora local del mercado (no de UTC). El
        # timestamp del bucket se reconvierte a epoch (key*secs - tz - phase).
        my $key = int(($c->{timestamp} + $tz + $phase) / $secs);

        if (!defined $bucket_key || $key != $bucket_key) {
            push @out, $bucket if $bucket;
            $bucket_key = $key;
            $bucket = {
                timestamp => $key * $secs - $tz - $phase,
                open      => $c->{open},
                high      => $c->{high},
                low       => $c->{low},
                close     => $c->{close},
                volume    => $c->{volume} || 0,
            };
        }
        else {
            $bucket->{high}   = $c->{high}  if $c->{high}  > $bucket->{high};
            $bucket->{low}    = $c->{low}   if $c->{low}   < $bucket->{low};
            $bucket->{close}  = $c->{close};
            $bucket->{volume} += $c->{volume} || 0;
        }
    }
    push @out, $bucket if $bucket;

    $self->{data}->{$tf} = \@out;
    $self->_recalc_effective_indices() if defined $self->{_replay_boundary};
    return \@out;
}

# build_timeframes()
# Construye todas las temporalidades superiores a partir de las velas de 1m.
# Todas se agregan SIEMPRE desde 1m (no en cascada), por lo que high/low/volume
# de cada barra son exactos y no se acumulan errores de redondeo entre TFs.
sub build_timeframes {
    my ($self) = @_;
    for my $tf (qw(5m 15m 1H 2H 4H 1D 1W)) {
        $self->build_tf_candles($tf);
    }
    return $self->{data};
}

# set_timeframe($tf)
# Selecciona la temporalidad activa (1m, 5m, 15m, 1H, 2H, 4H, 1D, 1W).
# devuelven get_slice, get_candle, size, etc. Reconstruye la TF si hace falta.
sub set_timeframe {
    my ($self, $tf) = @_;
    return unless $TF_MINUTES{$tf};

    if ($tf ne '1m') {
        my $arr = $self->{data}->{$tf};
        if (!$arr || !@$arr) {
            $self->build_tf_candles($tf);
        }
    }

    if (exists $self->{data}->{$tf} && @{ $self->{data}->{$tf} || [] }) {
        $self->{active_tf} = $tf;
        $self->{time_anchors} = [];
    }
    else {
        warn "Timeframe '$tf' no tiene datos.";
    }
    $self->_recalc_effective_indices() if defined $self->{_replay_boundary};
}

# active_tf() -> $tf
# Devuelve la temporalidad activa actual.
sub active_tf {
    my ($self) = @_;
    return $self->{active_tf};
}

# _active_array() -> \@candles
# Abstraccion interna: devuelve el array de velas de la temporalidad activa.
sub _active_array {
    my ($self) = @_;
    return $self->{data}->{ $self->{active_tf} } || [];
}

# get_slice($start, $end) -> \@candles
# Devuelve un subconjunto de velas [start..end] de la temporalidad activa.
# Acota indices fuera de rango y respeta la frontera de replay.
sub get_slice {
    my ($self, $start, $end) = @_;
    my $arr = $self->_active_array();
    return [] unless @$arr;

    if (defined $self->{_replay_boundary}) {
        my $eff_last = $self->{_effective_last_index}{$self->{active_tf}} // -1;
        $end = $eff_last if !defined $end || $end > $eff_last;
    } else {
        $end = $#$arr if !defined $end || $end > $#$arr;
    }

    $start = 0 if !defined $start || $start < 0;
    return []  if $start > $end;

    return [ @{$arr}[$start .. $end] ];
}

# get_candle($index) -> \%candle | undef
# Obtiene una vela por indice de la temporalidad activa (respetando replay).
sub get_candle {
    my ($self, $index) = @_;
    return unless defined $index;
    if (defined $self->{_replay_boundary}) {
        my $eff_last = $self->{_effective_last_index}{$self->{active_tf}} // -1;
        return if $index > $eff_last;
    }
    return $self->_active_array()->[$index];
}

# size() -> $n
# Numero total de velas de la temporalidad activa visibles.
sub size {
    my ($self) = @_;
    if (defined $self->{_replay_boundary}) {
        my $idx = $self->{_effective_last_index}{$self->{active_tf}};
        return defined $idx ? $idx + 1 : 0;
    }
    return scalar @{ $self->_active_array() };
}

# last_candle() -> \%candle
# Devuelve la ultima vela de la temporalidad activa visible.
sub last_candle {
    my ($self) = @_;
    my $idx = $self->last_index();
    return undef if $idx < 0;
    return $self->_active_array()->[$idx];
}

# last_index() -> $index
# Indice de la ultima vela visible (size - 1).
sub last_index {
    my ($self) = @_;
    return $self->size() - 1;
}

# raw_last_index() -> $index
# Indice real de la ultima vela de la temporalidad activa (ignorando replay).
sub raw_last_index {
    my ($self) = @_;
    return (scalar @{ $self->_active_array() }) - 1;
}

# raw_get_candle($index) -> \%candle | undef
# Obtiene una vela por indice real de la temporalidad activa (ignorando replay).
sub raw_get_candle {
    my ($self, $index) = @_;
    return unless defined $index;
    return $self->_active_array()->[$index];
}

# get_timestamp($index) -> $epoch | undef
# Obtiene el timestamp (epoch) de la vela en $index.
sub get_timestamp {
    my ($self, $index) = @_;
    my $c = $self->get_candle($index);
    return unless $c;
    return $c->{timestamp};
}

# merge_delta_row($delta_row)
# Actualizacion incremental (streaming): si el timestamp coincide con la
# ultima vela de la temporalidad activa, la actualiza; si no, agrega una
# vela nueva. Tras la actualizacion reconstruye las temporalidades superiores
# para mantener 5m y 15m sincronizadas con los datos de 1m.
sub merge_delta_row {
    my ($self, $delta_row) = @_;
    return unless $delta_row && ref $delta_row eq 'HASH';

    my $arr  = $self->_active_array();
    return unless $arr;
    my $last = $arr->[-1];

    if (   $last
        && defined $delta_row->{timestamp}
        && defined $last->{timestamp}
        && $last->{timestamp} == $delta_row->{timestamp})
    {
        # Actualiza la ultima vela in-place.
        for my $field (qw(open high low close volume)) {
            $last->{$field} = $delta_row->{$field} if defined $delta_row->{$field};
        }
    }
    else {
        push @$arr, $delta_row;
    }

    # Si la temporalidad activa es 1m, propaga a las temporalidades superiores.
    if ($self->{active_tf} eq '1m') {
        for my $tf (qw(5m 15m 1H 2H 4H 1D 1W)) {
            $self->build_tf_candles($tf) if exists $self->{data}->{$tf};
        }
    }
}

# compute_time_anchors() -> \@epochs
# Calcula y guarda la lista de timestamps de la temporalidad activa,
# usada como puntos de referencia para ejes/etiquetas de tiempo.
# Devuelve el array de epochs y lo almacena en $self->{time_anchors}.
sub compute_time_anchors {
    my ($self) = @_;
    my $arr = $self->_active_array();
    return [] unless @$arr;

    my @anchors = map { $_->{timestamp} } @$arr;
    $self->{time_anchors} = \@anchors;
    return \@anchors;
}

# get_time_anchors() -> \@epochs
# Devuelve los time_anchors calculados previamente (o los calcula si no existen).
sub get_time_anchors {
    my ($self) = @_;
    return $self->{time_anchors} if @{ $self->{time_anchors} };
    return $self->compute_time_anchors();
}

# -----------------------------------------------------------------------------
# Metodos para Market::Replay
# -----------------------------------------------------------------------------

sub set_replay_boundary {
    my ($self, $ts) = @_;
    $self->{_replay_boundary} = $ts;
    $self->_recalc_effective_indices();
}

sub get_replay_boundary {
    my ($self) = @_;
    return $self->{_replay_boundary};
}

sub clear_replay_boundary {
    my ($self) = @_;
    $self->{_replay_boundary} = undef;
    $self->{_effective_last_index} = {};
}

sub _recalc_effective_indices {
    my ($self) = @_;
    return unless defined $self->{_replay_boundary};
    my $ts = $self->{_replay_boundary};
    
    for my $tf (keys %{$self->{data}}) {
        my $arr = $self->{data}{$tf};
        my $idx = -1;
        if ($arr && @$arr) {
            my $low = 0;
            my $high = $#$arr;
            while ($low <= $high) {
                my $mid = int(($low + $high) / 2);
                if ($arr->[$mid]{timestamp} <= $ts) {
                    $idx = $mid;
                    $low = $mid + 1;
                } else {
                    $high = $mid - 1;
                }
            }
        }
        $self->{_effective_last_index}{$tf} = $idx;
    }
}

1;

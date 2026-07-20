package Market::Concepts::MTFLevels;

# =============================================================================
# Market::Concepts::MTFLevels  — v1.0
# =============================================================================
# Calcula los niveles High/Low de temporalidades superiores (D, W, M) y los
# proyecta sobre el gráfico activo.
#
# Solo se activa cuando la temporalidad ACTIVA del gráfico es estrictamente
# MENOR que la temporalidad del nivel (higherTimeframe() del Pine Script):
#   - PDH/PDL (Daily): visible en < 1D (1m, 5m, 15m, 1H, 2H, 4H)
#   - PWH/PWL (Weekly): visible en < 1W (1m, 5m, ..., 1D)
#   - PMH/PML (Monthly): siempre visible si la TF activa < 1M (aprox.)
#
# Fuente de datos: reutiliza $market_data->{data}{tf} ya construido por
# MarketData::build_tf_candles() — no duplica lógica de agregación.
#
# Para Monthly: MarketData no tiene '1M' nativo, así que se agrupa sobre
# los datos de '1D' usando buckets mes/año del timestamp.
#
# Salida de calculate():
#   {
#     daily   => { high => $p, low => $p, label_high => 'PDH', label_low => 'PDL',
#                  start_index => $i, end_index => $i, enabled => bool },
#     weekly  => { ... 'PWH'/'PWL' ... },
#     monthly => { ... 'PMH'/'PML' ... },
#   }
# =============================================================================

use strict;
use warnings;
use POSIX qw(floor);

# Minutos por temporalidad (igual que en MarketData)
my %TF_MINUTES = (
    '1m'  => 1,
    '5m'  => 5,
    '15m' => 15,
    '1H'  => 60,
    '2H'  => 120,
    '4H'  => 240,
    '1D'  => 1440,
    '1W'  => 10080,
    '1M'  => 43200,   # aprox. 30 días × 1440 min
);

sub new {
    my ($class, %args) = @_;
    my $self = {
        show_daily   => $args{show_daily}   // 1,
        show_weekly  => $args{show_weekly}  // 1,
        show_monthly => $args{show_monthly} // 1,
    };
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    return $self;
}

# calculate($market_data, %args) -> \%result
sub calculate {
    my ($self, $market_data, %args) = @_;
    my $empty = { daily => undef, weekly => undef, monthly => undef };
    return $empty unless $market_data;

    my $active_tf = $market_data->can('active_tf') ? $market_data->active_tf() : '1m';
    $active_tf //= '1m';
    my $active_min = $TF_MINUTES{$active_tf} // 1;

    my $total = $market_data->size();
    return $empty unless $total > 0;

    # Límite visible (respeta modo Replay)
    my $replay_controller = $args{replay_controller};
    my $visible_limit = defined $replay_controller && $replay_controller->can('visible_limit')
        ? $replay_controller->visible_limit($total)
        : undef;
    my $last_index = (defined $visible_limit && $visible_limit >= 0 && $visible_limit < $total)
        ? $visible_limit
        : ($total - 1);

    # Timestamp de la última vela visible (para saber qué período "anterior" necesitamos)
    my $last_candle = $market_data->get_candle($last_index);
    my $last_ts = $last_candle ? ($last_candle->{timestamp} // 0) : 0;

    my $result = { daily => undef, weekly => undef, monthly => undef };

    # ── Daily Levels (PDH/PDL) ────────────────────────────────────────────
    if ($args{show_daily} // $self->{show_daily}) {
        my $daily_min = $TF_MINUTES{'1D'};
        if ($active_min < $daily_min) {
            my $daily_data = _get_htf_prev_candle($market_data, '1D', $last_ts);
            if ($daily_data) {
                $result->{daily} = {
                    high        => $daily_data->{high},
                    low         => $daily_data->{low},
                    label_high  => 'PDH',
                    label_low   => 'PDL',
                    start_index => $daily_data->{start_bar_index} // 0,
                    end_index   => $last_index,
                    enabled     => 1,
                };
            }
        }
    }

    # ── Weekly Levels (PWH/PWL) ──────────────────────────────────────────
    if ($args{show_weekly} // $self->{show_weekly}) {
        my $weekly_min = $TF_MINUTES{'1W'};
        if ($active_min < $weekly_min) {
            my $weekly_data = _get_htf_prev_candle($market_data, '1W', $last_ts);
            if ($weekly_data) {
                $result->{weekly} = {
                    high        => $weekly_data->{high},
                    low         => $weekly_data->{low},
                    label_high  => 'PWH',
                    label_low   => 'PWL',
                    start_index => $weekly_data->{start_bar_index} // 0,
                    end_index   => $last_index,
                    enabled     => 1,
                };
            }
        }
    }

    # ── Monthly Levels (PMH/PML) ─────────────────────────────────────────
    if ($args{show_monthly} // $self->{show_monthly}) {
        my $monthly_min = $TF_MINUTES{'1M'};
        if ($active_min < $monthly_min) {
            my $monthly_data = _get_monthly_prev_candle($market_data, $last_ts);
            if ($monthly_data) {
                $result->{monthly} = {
                    high        => $monthly_data->{high},
                    low         => $monthly_data->{low},
                    label_high  => 'PMH',
                    label_low   => 'PML',
                    start_index => $monthly_data->{start_bar_index} // 0,
                    end_index   => $last_index,
                    enabled     => 1,
                };
            }
        }
    }

    return $result;
}

# =============================================================================
# PRIVATE — _get_htf_prev_candle($market_data, $tf, $current_ts)
# Obtiene el OHLC de la última vela CERRADA de la temporalidad $tf
# (la vela que contiene $current_ts no está cerrada — se necesita la anterior).
# Reutiliza el array ya construido por MarketData::build_tf_candles().
# Devuelve undef si no hay datos suficientes.
# =============================================================================
sub _get_htf_prev_candle {
    my ($market_data, $tf, $current_ts) = @_;

    # Obtener el array de velas de la temporalidad superior
    my $data_hash = $market_data->{data} // {};
    my $tf_candles = $data_hash->{$tf};

    # Si no está construido, intentar construirlo
    if (!$tf_candles || !@$tf_candles) {
        if ($market_data->can('build_tf_candles')) {
            $tf_candles = $market_data->build_tf_candles($tf);
        }
    }
    return undef unless $tf_candles && @$tf_candles;

    # La vela en formación es la que contiene current_ts.
    # La vela cerrada anterior a esa es la que buscamos.
    # Las velas están ordenadas cronológicamente → recorremos de atrás hacia adelante.
    my $prev_candle = undef;
    my $prev_candle_idx = undef;
    for (my $i = $#$tf_candles; $i >= 0; $i--) {
        my $c = $tf_candles->[$i];
        next unless $c && defined $c->{timestamp};
        if ($c->{timestamp} < $current_ts) {
            # Esta es la última vela cerrada antes del período actual
            $prev_candle     = $c;
            $prev_candle_idx = $i;
            last;
        }
    }
    return undef unless defined $prev_candle;

    # Aproximar el bar_index activo (en la temporalidad activa) al inicio
    # de esta vela HTF. Usamos el timestamp del previo para encontrar la
    # primera vela activa cuyo timestamp >= start de ese período HTF.
    my $start_bar = _approx_bar_index($market_data, $prev_candle->{timestamp});

    return {
        open            => $prev_candle->{open},
        high            => $prev_candle->{high},
        low             => $prev_candle->{low},
        close           => $prev_candle->{close},
        timestamp       => $prev_candle->{timestamp},
        start_bar_index => $start_bar,
    };
}

# =============================================================================
# PRIVATE — _get_monthly_prev_candle($market_data, $current_ts)
# MarketData no tiene '1M' nativo. Agrupamos sobre el array '1D' por mes/año
# usando el timestamp en UTC (aproximación suficiente para MTF levels).
# =============================================================================
sub _get_monthly_prev_candle {
    my ($market_data, $current_ts) = @_;

    my $data_hash  = $market_data->{data} // {};
    my $day_candles = $data_hash->{'1D'};

    if (!$day_candles || !@$day_candles) {
        if ($market_data->can('build_tf_candles')) {
            $day_candles = $market_data->build_tf_candles('1D');
        }
    }
    return undef unless $day_candles && @$day_candles;

    # Determinar el mes/año del período actual
    my @cur = gmtime($current_ts);
    my $cur_month = $cur[4];   # 0-11
    my $cur_year  = $cur[5];   # años desde 1900

    # Agrupar velas diarias en meses y encontrar el mes anterior al actual
    my %months;  # key = "YYYY-MM" => { open, high, low, close, ts_start, ts_end }
    for my $c (@$day_candles) {
        next unless $c && defined $c->{timestamp};
        my @t = gmtime($c->{timestamp});
        my $key = sprintf('%04d-%02d', $t[5] + 1900, $t[4]);
        if (!exists $months{$key}) {
            $months{$key} = {
                open      => $c->{open},
                high      => $c->{high},
                low       => $c->{low},
                close     => $c->{close},
                ts_start  => $c->{timestamp},
                ts_end    => $c->{timestamp},
            };
        } else {
            $months{$key}{high}   = $c->{high}  if $c->{high}  > $months{$key}{high};
            $months{$key}{low}    = $c->{low}   if $c->{low}   < $months{$key}{low};
            $months{$key}{close}  = $c->{close};
            $months{$key}{ts_end} = $c->{timestamp};
        }
    }

    my $cur_key = sprintf('%04d-%02d', $cur_year + 1900, $cur_month);

    # Ordenar claves cronológicamente y encontrar el mes anterior al actual
    my @sorted_keys = sort keys %months;
    my $prev_key;
    for my $k (@sorted_keys) {
        last if $k ge $cur_key;
        $prev_key = $k;
    }
    return undef unless defined $prev_key;

    my $mc = $months{$prev_key};
    my $start_bar = _approx_bar_index($market_data, $mc->{ts_start});

    return {
        open            => $mc->{open},
        high            => $mc->{high},
        low             => $mc->{low},
        close           => $mc->{close},
        timestamp       => $mc->{ts_start},
        start_bar_index => $start_bar,
    };
}

# =============================================================================
# PRIVATE — _approx_bar_index($market_data, $target_ts)
# Busca por bisección el índice de la primera vela cuyo timestamp >= $target_ts
# en la temporalidad activa. O(log N).
# =============================================================================
sub _approx_bar_index {
    my ($market_data, $target_ts) = @_;
    return 0 unless defined $target_ts;

    my $size = $market_data->size();
    return 0 unless $size > 0;

    my ($lo, $hi) = (0, $size - 1);
    my $best = 0;
    while ($lo <= $hi) {
        my $mid = int(($lo + $hi) / 2);
        my $c = $market_data->get_candle($mid);
        next unless $c && defined $c->{timestamp};
        if ($c->{timestamp} >= $target_ts) {
            $best = $mid;
            $hi = $mid - 1;
        } else {
            $lo = $mid + 1;
        }
        last if $lo > $hi;
    }
    return $best;
}

1;

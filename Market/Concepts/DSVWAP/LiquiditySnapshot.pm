package Market::Concepts::DSVWAP::LiquiditySnapshot;

use strict;
use warnings;
use POSIX qw(floor);

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::LiquiditySnapshot  v2.1
# =============================================================================
#
# OPTIMIZACIONES v2.1 (anti-bottleneck):
#   1. _TFView: ZERO-COPY — usa el array original con un tope last_idx;
#      elimina la copia O(N) de velas que causaba el cuello de botella.
#   2. SMC compartido: _run_smc() se llama UNA sola vez por TF por snapshot;
#      _run_ob y _run_fib reciben el smc_result ya calculado.
#   3. Memoizacion por (tf, closed_idx): si dos apariciones distintas caen
#      en el mismo bucket cerrado, los engines se ejecutan solo la primera
#      vez; el resultado se reutiliza en O(1).
# =============================================================================
#
# RESPONSABILIDAD UNICA:
#   Para un timestamp de aparicion de fantasma ($anchor_ts), construye un
#   snapshot inmutable de features de las 3 temporalidades (1m, 10m, 1H),
#   garantizando que NINGUN dato del futuro contamina el snapshot (anti-leakage).
#
# LOGICA ANTI-LEAKAGE (auditada en Paso 0):
#   1. find_closed_tf_index($tf, $anchor_ts) devuelve el indice del ultimo
#      bucket CERRADO de esa TF antes del momento de aparicion.
#   2. Si resultado es undef => TF sin datos previos => todos los campos undef.
#
# CAMPOS DEL SNAPSHOT (por TF: '1m', '10m', '1H'):
#   tf_Xm => {
#     # --- Vela base (anti-leakage ya garantizado) ---
#     open, high, low, close, volume, ts, index,
#
#     # --- Engines (niveles + PIP vs HLC3 de aparicion) ---
#
#     ob    => [ { type, high, low, price, pip_mid, pip_high, pip_low,
#                  state, kind, scope }, ... ],   # OrderBlocks activos
#
#     fvg   => [ { type, top, bottom, price, size, pip_top, pip_bottom,
#                  pip_mid, state }, ... ],        # FVGs activos
#
#     fib   => [ { level, price, pip }, ... ],     # Niveles Fibonacci
#
#     vwap  => {
#       vwap => $p,  pip_vwap => $d,
#       u1 => $p, l1 => $p, pip_u1 => $d, pip_l1 => $d,
#       u2 => $p, l2 => $p, pip_u2 => $d, pip_l2 => $d,
#     },
#
#     vp    => {
#       poc => $p,  pip_poc => $d,
#       vah => $p,  pip_vah => $d,
#       val => $p,  pip_val => $d,
#     },
#
#     mtf   => {
#       pdh => $p, pip_pdh => $d,
#       pdl => $p, pip_pdl => $d,
#       pwh => $p, pip_pwh => $d,
#       pwl => $p, pip_pwl => $d,
#     },
#
#     liq_events => [ { type, price, pip, dir, index }, ... ],
#                      # Sweep/Grab/Run de LiquidityDavid (solo eventos
#                      #   cuyos indices <= closed_idx)
#   } | undef
#
# NOTA: pip = abs(nivel - hlc3_aparicion) * 10000
#   (convencion Forex 5 digitos; para otros instrumentos ajustar pip_factor)
#
# =============================================================================

# Carga diferida de engines (no falla si no estan instalados)
my @_LOAD_ERRORS;

sub _try_require {
    my ($mod) = @_;
    eval "require $mod; 1" or do {
        push @_LOAD_ERRORS, $mod;
        return 0;
    };
    return 1;
}

# ---------------------------------------------------------------------------
# new()
# ---------------------------------------------------------------------------
sub new {
    my ($class, %args) = @_;
    # pip_factor: 10000 para Forex 5-digit (XAU/USD usa 10, indices ~1, etc.)
    # Se puede sobreescribir: LiquiditySnapshot->new(pip_factor => 10)
    #
    # window_1m : maximo de velas 1m que se pasan a los engines (default 500).
    #   Para 1m con 18k velas, los OBs/FVGs mas viejos de 500 barras no son
    #   utiles para ML; limitar aqui reduce O(18000) a O(500) por aparicion.
    # window_10m: idem para 10m (default 300 velas = 50 horas de contexto).
    my $self = {
        pip_factor  => $args{pip_factor}  // 10000,
        window_1m   => $args{window_1m}   // 500,
        window_10m  => $args{window_10m}  // 300,
        # Cache de engines por (tf, closed_idx) — elimina recomputos en buckets identicos
        _memo_cache => {},
    };
    return bless $self, $class;
}

# ---------------------------------------------------------------------------
# snapshot_for_anchor($market_data, $anchor_ts, $anchor_index) -> \%snapshot
# ---------------------------------------------------------------------------
sub snapshot_for_anchor {
    my ($self, $market_data, $anchor_ts, $anchor_index) = @_;

    my $empty = {
        anchor_ts    => $anchor_ts,
        anchor_index => $anchor_index,
        tf_1m        => undef,
        tf_10m       => undef,
        tf_1h        => undef,
    };
    return $empty unless $market_data && defined $anchor_ts;

    # --- Precio de referencia HLC3 de la vela de aparicion ---
    my $anchor_candle = $market_data->get_candle($anchor_index // 0);
    my $ref_price = undef;
    if ($anchor_candle) {
        $ref_price = ( ($anchor_candle->{high}  // 0)
                     + ($anchor_candle->{low}   // 0)
                     + ($anchor_candle->{close} // 0) ) / 3;
    }

    return {
        anchor_ts    => $anchor_ts,
        anchor_index => $anchor_index,
        ref_price    => $ref_price,
        tf_1m        => $self->_build_tf_snapshot($market_data, '1m',  $anchor_ts, $anchor_index, $ref_price),
        tf_10m       => $self->_build_tf_snapshot($market_data, '10m', $anchor_ts, $anchor_index, $ref_price),
        tf_1h        => $self->_build_tf_snapshot($market_data, '1H',  $anchor_ts, $anchor_index, $ref_price),
    };
}

# ===========================================================================
# _build_tf_snapshot($md, $tf, $anchor_ts, $anchor_index, $ref_price)
# Construye el snapshot completo de una temporalidad.
# Para '1m': usa $anchor_index directamente (la vela de aparicion ya es 1m).
# Para '10m'/'1H': usa find_closed_tf_index para anti-leakage.
# ===========================================================================
sub _build_tf_snapshot {
    my ($self, $market_data, $tf, $anchor_ts, $anchor_index, $ref_price) = @_;

    my ($closed_idx, $candle_data, $view_first_idx);

    if ($tf eq '1m') {
        # Para 1m: el indice de aparicion ES el ultimo cerrado antes de la aparicion.
        # Usamos $anchor_index - 1 para no incluir la vela en formacion.
        my $idx_1m = ($anchor_index // 0) - 1;
        return undef if $idx_1m < 0;

        my $c = $market_data->get_candle($idx_1m);
        return undef unless $c;

        $closed_idx  = $idx_1m;
        $candle_data = {
            open   => $c->{open},
            high   => $c->{high},
            low    => $c->{low},
            close  => $c->{close},
            volume => $c->{volume},
            ts     => $c->{timestamp},
            index  => $closed_idx,
        };

        # OPTIMIZACION 4: Ventana deslizante para 1m
        # Los engines de 1m solo necesitan las ultimas window_1m velas para
        # detectar OBs/FVGs relevantes. Procesar 18k velas por aparicion es
        # innecesario y el cuello de botella principal.
        my $win = $self->{window_1m};
        $view_first_idx = ($closed_idx >= $win) ? ($closed_idx - $win + 1) : 0;

    } else {
        # Para TFs superiores: logica anti-leakage via find_closed_tf_index
        $closed_idx = $market_data->find_closed_tf_index($tf, $anchor_ts);
        return undef unless defined $closed_idx;

        my $c = $market_data->get_candle_in_tf($tf, $closed_idx);
        return undef unless $c;

        $candle_data = {
            open   => $c->{open},
            high   => $c->{high},
            low    => $c->{low},
            close  => $c->{close},
            volume => $c->{volume},
            ts     => $c->{timestamp},
            index  => $closed_idx,
        };

        # Ventana deslizante para 10m (1H tiene pocos buckets: memo cubre bien)
        if ($tf eq '10m') {
            my $win = $self->{window_10m};
            $view_first_idx = ($closed_idx >= $win) ? ($closed_idx - $win + 1) : 0;
        } else {
            $view_first_idx = 0;   # 1H: pocos buckets, memo hace el trabajo
        }
    }

    # -----------------------------------------------------------------
    # OPTIMIZACION 3: Memoizacion por (tf, closed_idx)
    # Para 1m y 10m con ventana: la clave incluye tambien view_first_idx
    # para que dos apariciones con la misma ventana exacta compartan cache.
    # -----------------------------------------------------------------
    my $memo_key = "${tf}:${view_first_idx}:${closed_idx}";
    my $engines_cached = $self->{_memo_cache}{$memo_key};

    unless ($engines_cached) {
        # Construir vista de datos para engines (zero-copy + ventana deslizante)
        my $view = $self->_make_tf_view($market_data, $tf, $closed_idx, $view_first_idx);
        return undef unless $view && $view->size() > 0;

        # OPTIMIZACION 2: SMC se computa UNA sola vez y se comparte entre OB y Fib
        my $smc_result = $self->_run_smc($view, $tf);

        $engines_cached = {
            ob_data   => $self->_run_ob($view, $tf, $smc_result),
            fvg_data  => $self->_run_fvg($view, $tf),
            fib_data  => $self->_run_fib($view, $tf, $smc_result),
            vwap_data => $self->_run_vwap($view, $tf),
            vp_data   => $self->_run_vp($view, $tf, $closed_idx),
            mtf_data  => $self->_run_mtf($market_data, $tf, $anchor_ts, $closed_idx),
            liq_data  => $self->_run_liq($view, $tf, $market_data, $closed_idx),
            smc_data  => $smc_result,
        };
        $self->{_memo_cache}{$memo_key} = $engines_cached;
    }

    # Precio de referencia: HLC3 de la vela de aparicion (1m)
    # Si $ref_price no esta definido lo usamos como 0 (los PIPs serian relativos a 0)
    my $rp = $ref_price // 0;
    my $smc = $engines_cached->{smc_data};

    return {
        %$candle_data,

        # Order Blocks (nivel + rango/espesor + PIPs)
        ob => $self->_pips_ob($engines_cached->{ob_data}, $rp),

        # FVGs (nivel + rango/espesor + PIPs)
        fvg => $self->_pips_fvg($engines_cached->{fvg_data}, $rp),

        # Fibonacci (niveles + PIPs)
        fib => $self->_pips_fib($engines_cached->{fib_data}, $rp),

        # VWAP + bandas (nivel + PIPs)
        vwap => $self->_pips_vwap($engines_cached->{vwap_data}, $rp),

        # Volume Profile: POC/VAH/VAL + PIPs
        vp => $self->_pips_vp($engines_cached->{vp_data}, $rp),

        # MTF Levels: PDH/PDL, PWH/PWL + PIPs
        mtf => $self->_pips_mtf($engines_cached->{mtf_data}, $rp),

        # LiquidityDavid: Sweep/Grab/Run events + PIPs
        liq_events => $self->_pips_liq($engines_cached->{liq_data}, $rp),

        # PASO 0: SMC estructura (BOS/CHoCH) y Equal High/Low, usando events de smc_result
        structure_events => $self->_pips_structure($smc ? $smc->{events} : [], $rp),
        eq_events        => $self->_pips_eq($smc        ? $smc->{events} : [], $rp),
    };
}

# ===========================================================================
# _make_tf_view($md, $tf, $last_idx)
# Crea un objeto "duck-type" compatible con la API de MarketData que
# expone solo las velas [0 .. $last_idx] de la TF indicada.
# Implementa: size(), get_candle($i), last_candle(), last_index(),
#             active_tf(), get_slice($s,$e)
# NO muta $md en absoluto.
#
# OPTIMIZACION 1 (v2.1): ZERO-COPY
#   En lugar de hacer [ @{$arr}[0..$real_last] ] (copia O(N) de velas),
#   pasamos la referencia al array original mas el limite $real_last.
#   _TFView usa ese limite para simular un array truncado sin copiar nada.
# ===========================================================================
sub _make_tf_view {
    my ($self, $md, $tf, $last_idx, $first_idx) = @_;
    return undef unless defined $md && defined $tf && defined $last_idx;
    return undef if $last_idx < 0;

    $first_idx //= 0;
    $first_idx = 0 if $first_idx < 0;

    # Obtener array de velas de la TF (puede estar en data{$tf} o ser 1m)
    my $arr;
    if ($tf eq '1m') {
        $arr = $md->{data}{'1m'} || [];
    } else {
        # Garantizar construccion de la TF si aun no existe
        if (!exists $md->{data}{$tf} || !@{ $md->{data}{$tf} || [] }) {
            $md->build_tf_candles($tf);
        }
        $arr = $md->{data}{$tf} || [];
    }

    my $real_last = $last_idx;
    $real_last = $#$arr if $real_last > $#$arr;

    # ZERO-COPY con ventana deslizante: pasamos referencia + [first, last].
    # _TFView mapeara el indice i (relativo a la ventana) al elemento
    # arr[first_idx + i], sin copiar el array.
    return _TFView->new($arr, $tf, $real_last, $first_idx);
}

# ===========================================================================
# MOTORES
# ===========================================================================

# ---------------------------------------------------------------------------
# _run_smc($view, $tf) -> $smc_result | undef
# NUEVO (v2.1): corre SMCStructureEngine UNA sola vez por TF por snapshot.
# El resultado se pasa a _run_ob y _run_fib para evitar doble computo.
# ---------------------------------------------------------------------------
sub _run_smc {
    my ($self, $view, $tf) = @_;
    return undef unless _try_require('Market::Concepts::SMCStructureEngine');

    my $size = $view->size();
    return undef if $size < 3;

    my $smc = Market::Concepts::SMCStructureEngine->new(
        swing_length    => _tf_swing_len($tf, $size),
        internal_length => _tf_internal_len($tf, $size),
    );
    return eval { $smc->calculate($view) } // undef;
}

# ---------------------------------------------------------------------------
# _run_ob($view, $tf, $smc_result) -> \@active_blocks
# Ejecuta OrderBlockEngine sobre $view usando el $smc_result ya calculado.
# ---------------------------------------------------------------------------
sub _run_ob {
    my ($self, $view, $tf, $smc_result) = @_;
    return [] unless _try_require('Market::Concepts::OrderBlockEngine');
    return [] unless $smc_result;

    my $size = $view->size();
    return [] if $size < 5;

    my $obe = Market::Concepts::OrderBlockEngine->new();
    my $ob_result = eval { $obe->calculate($view, $smc_result) } or return [];

    return $ob_result->{active} || [];
}

# ---------------------------------------------------------------------------
# _run_fvg($view, $tf) -> \@active_fvgs
# ---------------------------------------------------------------------------
sub _run_fvg {
    my ($self, $view, $tf) = @_;
    return [] unless _try_require('Market::Concepts::FVGEngine');

    my $size = $view->size();
    return [] if $size < 4;

    my $fvg = Market::Concepts::FVGEngine->new();
    my $result = eval { $fvg->calculate($view) } or return [];
    return $result->{active} || [];
}

# ---------------------------------------------------------------------------
# _run_fib($view, $tf, $smc_result) -> \@fib_levels
# Ejecuta FibonacciEngine usando el $smc_result ya calculado.
# ---------------------------------------------------------------------------
sub _run_fib {
    my ($self, $view, $tf, $smc_result) = @_;
    return [] unless _try_require('Market::Concepts::FibonacciEngine');
    return [] unless $smc_result;

    my $size = $view->size();
    return [] if $size < 3;

    my $fib = Market::Concepts::FibonacciEngine->new();
    my $result = eval { $fib->calculate($view, $smc_result) } or return [];
    return $result->{active} || [];
}

# ---------------------------------------------------------------------------
# _run_vwap($view, $tf) -> \%vwap_data  {vwap, std_dev, u1, l1, u2, l2}
# Implementacion batch VWAP + Welford (sin depender de VWAPEngine/EventBus).
# Itera sobre TODAS las velas del view para calcular un VWAP anclado al inicio.
# ---------------------------------------------------------------------------
sub _run_vwap {
    my ($self, $view, $tf) = @_;
    my $n = $view->size();
    return {} if $n < 1;

    my ($cum_vol, $cum_pv, $cum_pv2) = (0, 0, 0);

    for my $i (0 .. $n - 1) {
        my $c = $view->get_candle($i);
        next unless $c;
        my $hlc3 = ( ($c->{high}  // 0)
                   + ($c->{low}   // 0)
                   + ($c->{close} // 0) ) / 3;
        my $vol = $c->{volume} || 1;
        $cum_vol  += $vol;
        $cum_pv   += $hlc3 * $vol;
        $cum_pv2  += $hlc3 * $hlc3 * $vol;
    }

    return {} if $cum_vol <= 0;

    my $vwap    = $cum_pv / $cum_vol;
    my $mean_p2 = $cum_pv2 / $cum_vol;
    my $var     = $mean_p2 - $vwap * $vwap;
    $var = 0 if $var < 0;
    my $std     = sqrt($var);

    return {
        vwap => $vwap,
        std  => $std,
        u1   => $vwap + $std,
        l1   => $vwap - $std,
        u2   => $vwap + 2 * $std,
        l2   => $vwap - 2 * $std,
    };
}

# ---------------------------------------------------------------------------
# _run_vp($view, $tf, $last_idx) -> \%vp_data  {poc, vah, val}
# ---------------------------------------------------------------------------
sub _run_vp {
    my ($self, $view, $tf, $last_idx) = @_;
    return {} unless _try_require('Market::Volume::SessionProfile');

    my $n = $view->size();
    return {} if $n < 2;

    my $sp = Market::Volume::SessionProfile->new();
    my $result = eval {
        $sp->calculate($view, start_index => 0, end_index => $n - 1)
    } or return {};

    return {} unless ref $result eq 'HASH';
    my $poc = $result->{poc}        || {};
    my $va  = $result->{value_area} || {};

    return {
        poc => $poc->{price},
        vah => $va->{value_area_high},
        val => $va->{value_area_low},
    };
}

# ---------------------------------------------------------------------------
# _run_mtf($md, $tf, $anchor_ts, $closed_idx) -> \%mtf_data
# Llama MTFLevels con un wrapper que simula active_tf = $tf.
# Solo extrae niveles D/W (M es aproximado y menos relevante para snapshot).
# ---------------------------------------------------------------------------
sub _run_mtf {
    my ($self, $md, $tf, $anchor_ts, $closed_idx) = @_;
    return {} unless _try_require('Market::Concepts::MTFLevels');

    # MTFLevels usa active_tf() para decidir si los niveles D/W son relevantes.
    # Necesitamos un wrapper que le muestre la TF correcta y los datos hasta
    # $anchor_ts (usamos el MarketData real pero le pasamos un "active_tf" distinto
    # mediante un wrapper ligero).
    my $mtf_view = _MTFView->new($md, $tf, $closed_idx);

    my $mtf = Market::Concepts::MTFLevels->new(
        show_daily   => 1,
        show_weekly  => 1,
        show_monthly => 0,   # No incluimos monthly (aproximacion demasiado gruesa)
    );

    my $result = eval { $mtf->calculate($mtf_view) } or return {};
    return $result || {};
}

# ---------------------------------------------------------------------------
# _run_liq($view, $tf, $md, $closed_idx) -> \@events
# Ejecuta LiquidityDavid sobre la vista de la TF y devuelve solo los
# eventos (Sweep/Grab/Run) detectados hasta $closed_idx.
# LiquidityDavid requiere un ATR externo: lo calculamos inline con ATR(14).
# ---------------------------------------------------------------------------
sub _run_liq {
    my ($self, $view, $tf, $md, $closed_idx) = @_;
    return [] unless _try_require('Market::Indicators::ATR')
                  && _try_require('Market::Indicators::LiquidityDavid');

    my $n = $view->size();
    return [] if $n < 10;

    # Calcular ATR(14) inline sobre la vista
    my $atr = Market::Indicators::ATR->new(14);
    for my $i (0 .. $n - 1) {
        $atr->update_at_index($view, $i);
    }

    # LiquidityDavid sin zigzag externo (zzmtf/zzvp = undef):
    # solo usa su mecanismo interno de fractales.
    my $liq = Market::Indicators::LiquidityDavid->new(
        atr   => $atr,
        zzmtf => undef,
        zzvp  => undef,
    );

    eval { $liq->recompute($view) };
    return [] if $@;

    return $liq->get_events() || [];
}

# ===========================================================================
# CONVERSION A PIPs
# ===========================================================================

# _to_pips($level, $ref_price) -> $distance_in_pips (always >= 0)
# 1 PIP = 1 / pip_factor (por defecto pip_factor = 10000 → 1 pip = 0.0001)
sub _to_pips {
    my ($self, $level, $ref_price) = @_;
    return undef unless defined $level && defined $ref_price;
    return abs($level - $ref_price) * $self->{pip_factor};
}

# _signed_pips($level, $ref_price) -> signed pip (positive = level > ref_price)
# Mismo patron que liq_events pero con signo para distinguir above/below.
sub _signed_pips {
    my ($self, $level, $ref_price) = @_;
    return undef unless defined $level && defined $ref_price;
    return ($level - $ref_price) * $self->{pip_factor};
}

# ---------------------------------------------------------------------------
# _pips_structure($events_aref, $rp)
# PASO 0: filtra de $smc_result->{events} solo los BOS y CHoCH.
# Devuelve: [ { kind, direction, index, level, pip }, ... ]
# pip tiene SIGNO: positivo si level > ref_price (nivel above), negativo si below.
# ---------------------------------------------------------------------------
sub _pips_structure {
    my ($self, $events, $rp) = @_;
    return [] unless ref $events eq 'ARRAY';
    my @out;
    for my $e (@$events) {
        next unless ref $e eq 'HASH';
        next unless defined $e->{kind};
        next unless $e->{kind} eq 'BOS' || $e->{kind} eq 'CHoCH';
        push @out, {
            kind      => $e->{kind},
            direction => $e->{direction},
            index     => $e->{index},
            level     => $e->{level},
            pip       => $self->_signed_pips($e->{level}, $rp),
        };
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# _pips_eq($events_aref, $rp)
# PASO 0: filtra de $smc_result->{events} solo los EQH y EQL.
# Devuelve: [ { kind, index, level, pip }, ... ]
# pip tiene SIGNO: positivo si level > ref_price, negativo si below.
# ---------------------------------------------------------------------------
sub _pips_eq {
    my ($self, $events, $rp) = @_;
    return [] unless ref $events eq 'ARRAY';
    my @out;
    for my $e (@$events) {
        next unless ref $e eq 'HASH';
        next unless defined $e->{kind};
        next unless $e->{kind} eq 'EQH' || $e->{kind} eq 'EQL';
        push @out, {
            kind  => $e->{kind},
            index => $e->{index},
            level => $e->{level},
            pip   => $self->_signed_pips($e->{level}, $rp),
        };
    }
    return \@out;
}


sub _pips_ob {
    my ($self, $blocks, $rp) = @_;
    return [] unless ref $blocks eq 'ARRAY';
    my @out;
    for my $b (@$blocks) {
        next unless ref $b eq 'HASH';
        push @out, {
            type      => $b->{type},
            kind      => $b->{kind},
            scope     => $b->{scope},
            state     => $b->{state},
            high      => $b->{high},
            low       => $b->{low},
            price     => $b->{price},    # midpoint
            thickness => defined $b->{high} && defined $b->{low}
                         ? ($b->{high} - $b->{low}) : undef,
            pip_mid   => $self->_to_pips($b->{price}, $rp),
            pip_high  => $self->_to_pips($b->{high},  $rp),
            pip_low   => $self->_to_pips($b->{low},   $rp),
            index     => $b->{index},
        };
    }
    return \@out;
}

sub _pips_fvg {
    my ($self, $fvgs, $rp) = @_;
    return [] unless ref $fvgs eq 'ARRAY';
    my @out;
    for my $f (@$fvgs) {
        next unless ref $f eq 'HASH';
        push @out, {
            type       => $f->{type},
            state      => $f->{state},
            top        => $f->{top},
            bottom     => $f->{bottom},
            price      => $f->{price},   # midpoint
            size       => $f->{size},    # espesor = top - bottom
            pip_top    => $self->_to_pips($f->{top},    $rp),
            pip_bottom => $self->_to_pips($f->{bottom}, $rp),
            pip_mid    => $self->_to_pips($f->{price},  $rp),
            index      => $f->{index},
        };
    }
    return \@out;
}

sub _pips_fib {
    my ($self, $fibs, $rp) = @_;
    return [] unless ref $fibs eq 'ARRAY';
    my @out;
    for my $f (@$fibs) {
        next unless ref $f eq 'HASH';
        push @out, {
            level => $f->{level},
            price => $f->{price},
            pip   => $self->_to_pips($f->{price}, $rp),
        };
    }
    return \@out;
}

sub _pips_vwap {
    my ($self, $v, $rp) = @_;
    return {} unless ref $v eq 'HASH' && defined $v->{vwap};
    return {
        vwap     => $v->{vwap},
        std      => $v->{std},
        u1       => $v->{u1},
        l1       => $v->{l1},
        u2       => $v->{u2},
        l2       => $v->{l2},
        pip_vwap => $self->_to_pips($v->{vwap}, $rp),
        pip_u1   => $self->_to_pips($v->{u1},   $rp),
        pip_l1   => $self->_to_pips($v->{l1},   $rp),
        pip_u2   => $self->_to_pips($v->{u2},   $rp),
        pip_l2   => $self->_to_pips($v->{l2},   $rp),
        # Espesor de banda (= 2 * std en pips)
        band1_thickness_pip => defined $v->{std} ? 2 * $v->{std} * $self->{pip_factor} : undef,
        band2_thickness_pip => defined $v->{std} ? 4 * $v->{std} * $self->{pip_factor} : undef,
    };
}

sub _pips_vp {
    my ($self, $vp, $rp) = @_;
    return {} unless ref $vp eq 'HASH';
    return {
        poc     => $vp->{poc},
        vah     => $vp->{vah},
        val     => $vp->{val},
        pip_poc => $self->_to_pips($vp->{poc}, $rp),
        pip_vah => $self->_to_pips($vp->{vah}, $rp),
        pip_val => $self->_to_pips($vp->{val}, $rp),
        # Espesor del Value Area en pips
        va_thickness_pip => (defined $vp->{vah} && defined $vp->{val})
                            ? abs($vp->{vah} - $vp->{val}) * $self->{pip_factor}
                            : undef,
    };
}

sub _pips_mtf {
    my ($self, $mtf, $rp) = @_;
    return {} unless ref $mtf eq 'HASH';
    my %out;
    if (my $d = $mtf->{daily}) {
        $out{pdh}     = $d->{high};
        $out{pdl}     = $d->{low};
        $out{pip_pdh} = $self->_to_pips($d->{high}, $rp);
        $out{pip_pdl} = $self->_to_pips($d->{low},  $rp);
    }
    if (my $w = $mtf->{weekly}) {
        $out{pwh}     = $w->{high};
        $out{pwl}     = $w->{low};
        $out{pip_pwh} = $self->_to_pips($w->{high}, $rp);
        $out{pip_pwl} = $self->_to_pips($w->{low},  $rp);
    }
    return \%out;
}

sub _pips_liq {
    my ($self, $events, $rp) = @_;
    return [] unless ref $events eq 'ARRAY';
    my @out;
    for my $e (@$events) {
        next unless ref $e eq 'HASH';
        push @out, {
            type  => $e->{type},
            dir   => $e->{dir},
            price => $e->{price},
            index => $e->{index},
            pip   => $self->_to_pips($e->{price}, $rp),
        };
    }
    return \@out;
}

# ===========================================================================
# Helpers de parametros adaptativos por TF
# ===========================================================================

sub _tf_swing_len {
    my ($tf, $size) = @_;
    my %defaults = (
        '1m'  => 50,
        '10m' => 20,
        '1H'  => 10,
    );
    my $len = $defaults{$tf} // 50;
    # Clamp: no puede ser mayor que floor(size/3) ni menor que 3
    my $max = floor($size / 3);
    $len = $max if $len > $max;
    $len = 3    if $len < 3;
    return $len;
}

sub _tf_internal_len {
    my ($tf, $size) = @_;
    my %defaults = (
        '1m'  => 5,
        '10m' => 3,
        '1H'  => 2,
    );
    my $len = $defaults{$tf} // 5;
    my $max = floor($size / 4);
    $len = $max if $len > $max;
    $len = 2    if $len < 2;
    return $len;
}

# ===========================================================================
# _TFView — objeto duck-type que emula la API de MarketData
# sobre un array de velas de una TF especifica.
#
# OPTIMIZACION v2.1 — ZERO-COPY:
#   Recibe la referencia al array ORIGINAL de MarketData (no una copia)
#   mas un indice tope $last. Todos los metodos respetan ese tope.
#   Esto elimina la copia O(N) que causaba el cuello de botella: para
#   1m con 18 000 velas x 309 apariciones = 0 bytes copiados.
# ===========================================================================
package _TFView;

# new($arr, $tf, $last, $first)
#   $arr  : referencia al array completo de velas (NO se copia)
#   $tf   : string de la temporalidad ('1m', '10m', '1H', ...)
#   $last : indice ABSOLUTO del ultimo elemento visible (en $arr)
#   $first: indice ABSOLUTO del primer elemento visible (ventana deslizante)
#
# La vista expone indices RELATIVOS [0 .. size-1] al exterior.
# Internamente: arr[first + i_relativo].
# Esto permite ventanas deslizantes sin ninguna copia de memoria.
sub new {
    my ($class, $arr, $tf, $last, $first) = @_;
    $arr   //= [];
    $first //= 0;
    $last  //= $#$arr;
    $last  = $#$arr if $last  > $#$arr;
    $last  = -1     if $last  < -1;
    $first = 0      if $first < 0;
    $first = $last  if $first > $last && $last >= 0;
    my $size = ($last >= $first) ? ($last - $first + 1) : 0;
    return bless {
        arr   => $arr,
        tf    => $tf || '1m',
        first => $first,
        last  => $last,
        size  => $size,
    }, $class;
}

sub size        { $_[0]->{size} }
sub active_tf   { $_[0]->{tf} }
sub last_index  { $_[0]->{size} - 1 }  # indice RELATIVO

sub get_candle {
    my ($self, $i) = @_;          # $i es RELATIVO a la ventana
    return undef unless defined $i && $i >= 0 && $i < $self->{size};
    return $self->{arr}[ $self->{first} + $i ];
}

sub last_candle {
    my ($self) = @_;
    return undef if $self->{size} <= 0;
    return $self->{arr}[ $self->{last} ];
}

sub get_slice {
    my ($self, $s, $e) = @_;      # $s, $e son indices RELATIVOS
    $s //= 0;
    $e //= $self->{size} - 1;
    $s = 0                   if $s < 0;
    $e = $self->{size} - 1   if $e >= $self->{size};
    return [] if $s > $e || $self->{size} <= 0;
    my $as = $self->{first} + $s;
    my $ae = $self->{first} + $e;
    return [ @{ $self->{arr} }[$as .. $ae] ];
}

# Para compatibilidad con engines que llaman raw_get_candle
sub raw_get_candle { return $_[0]->get_candle($_[1]) }
sub raw_last_index { return $_[0]->last_index() }

# ===========================================================================
# _MTFView — wrapper de MarketData que sobreescribe active_tf()
# para que MTFLevels crea que la TF activa es la del snapshot.
# MTFLevels accede $md->{data}{tf} directamente (hash desnudo), por lo que
# heredamos ese hash del MarketData subyacente via overloading del acceso.
# ===========================================================================
package _MTFView;

use strict;
use warnings;

sub new {
    my ($class, $md, $tf, $closed_idx) = @_;
    # Exponemos el hash {data} del MarketData subyacente directamente
    # para que MTFLevels pueda hacer $md->{data}{'1D'} sin problema.
    return bless {
        _md         => $md,
        _tf         => $tf,
        _closed_idx => $closed_idx,
        data        => $md->{data},   # referencia compartida (lectura solo)
    }, $class;
}

# active_tf sobreescrito: le mentimos a MTFLevels sobre la TF activa
sub active_tf   { $_[0]->{_tf} }

# Resto de la API delega al MarketData real
sub size        { $_[0]->{_md}->size()       }
sub get_candle  { $_[0]->{_md}->get_candle($_[1]) }
sub last_candle { $_[0]->{_md}->last_candle() }
sub last_index  { $_[0]->{_md}->last_index() }
sub get_slice   { $_[0]->{_md}->get_slice($_[1], $_[2]) }

# can() correcto: usa UNIVERSAL::can para evitar recursion
sub can {
    my ($self, $method) = @_;
    return UNIVERSAL::can($self, $method) // UNIVERSAL::can($self->{_md}, $method);
}

# AUTOLOAD: delega metodos no definidos al MarketData subyacente
our $AUTOLOAD;
sub AUTOLOAD {
    my ($self, @args) = @_;
    my $method = $AUTOLOAD;
    $method =~ s/.*:://;
    return if $method eq 'DESTROY';
    my $md = $self->{_md};
    return $md->$method(@args) if $md && UNIVERSAL::can($md, $method);
}

package Market::Concepts::DSVWAP::LiquiditySnapshot;

1;


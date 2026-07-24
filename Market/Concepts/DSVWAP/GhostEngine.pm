package Market::Concepts::DSVWAP::GhostEngine;

use strict;
use warnings;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::GhostEngine
# =============================================================================
#
# TRANSCRIPCION ESTRUCTURAL del bloque barstate.islast del algoritmo original:
#   "Dynamic Swing Anchored VWAP by Josafa" (Pine Script v6, LuxAlgo)
#
# CORRESPONDENCIA DIRECTA CON EL ORIGINAL:
#
#   ORIGINAL (barstate.islast)              ESTE MODULO
#   ─────────────────────────────────────   ────────────────────────────────────
#   $live_ghost_label = delete_label(..)    $c->clear_ghost()  [_publish_snapshot]
#   my $x_last = 0; my $y_last = 0.0;      _find_extreme() retorna ($x_last,$y_last)
#   for (i=0; i<=b-px1-1; i++) {           _find_extreme(): bucle identico +
#     low/high ... }                          comparacion directa (ver justificacion)
#   min(@prices)/max(@prices) + grep        _find_extreme(): comparacion en una pasada
#   draw_line(px1,py1->x_last,y_last)       _publish_snapshot: ghost_line
#   draw_label(x_last, y_last)              _publish_snapshot: ghost_label
#   my $ghost_cumVol = 0.0;                 _compute_ghost_vwap: var local (= reset)
#   my $ghost_cumPriceVol = 0.0;            _compute_ghost_vwap: var local
#   my $ghost_sumSqDiff = 0.0;              _compute_ghost_vwap: var local
#   for (i=ghost_barsback; i>=0; i--)       _compute_ghost_vwap: bucle identico
#   push ghostVwapData points               _compute_ghost_vwap: @ghost_vwap_pts
#   push ghostBandsData u1/l1/u2/l2/u3/l3  _compute_ghost_vwap: @bands_u1..@bands_l3
#   draw_polyline(ghostVwapData, ...)        _publish_snapshot: ghost_vwap, bands_*
#
# VARIABLES "var" DEL ORIGINAL Y SU EQUIVALENTE AQUI:
#   $px1  => $anchor->{x}   (llega via AnchorChangedEvent)
#   $py1  => $anchor->{y}   (llega via AnchorChangedEvent)
#   $os   => derivado de $anchor->{dir}: dir==-1 => os=1 ; dir==1 => os=0
#   $b    => $index         (llega via NewBarEvent)
#
# ESTADO ELIMINADO (prohibido por las REGLAS):
#   candidate_extreme, ghost_position, ghost_path (artefacto sin equivalente
#   en el original), preview_anchor, last_rendered_position,
#   vwap_state (acumulador Welford incremental)
#
# NOTA ghost_path:
#   El codigo original de LuxAlgo NO posee ninguna estructura equivalente
#   a ghost_path. Ha sido eliminada completamente. El campo ghost_path del
#   StateCache recibe undef (no un array vacio) para reflejar fielmente
#   la ausencia del concepto en el original.
# =============================================================================


sub new {
    my ($class, $event_bus, $cache, $price_source, $show_miss) = @_;
    my $self = {
        bus          => $event_bus,
        cache        => $cache,
        price_source => $price_source || 'HLC3',
        show_miss    => $show_miss // 1,

        # Estado minimo: el ancla confirmada.
        # Equivale a las variables "var" px1, py1, os del original,
        # que son persistentes entre barras y actualizadas por
        # get_swing_pivots() cada vez que se detecta un pivot.
        # En la arquitectura modular, este dato llega via AnchorChangedEvent.
        confirmed_anchor => undef,
    };

    bless $self, $class;

    $self->{bus}->subscribe('NewBarEvent',        sub { $self->_on_tick(@_) });
    $self->{bus}->subscribe('AnchorChangedEvent', sub { $self->_on_anchor_changed(@_) });

    return $self;
}

# reset(): limpia el ancla y publica un snapshot vacio.
# Equivale al estado inicial de las variables "var" del original (todas en 0/undef).
sub reset {
    my ($self) = @_;
    $self->{confirmed_anchor} = undef;
    $self->_publish_snapshot();
}

# _on_anchor_changed(): actualiza el ancla cuando AnchorResolver detecta un nuevo pivot.
# Equivale al momento en que get_swing_pivots() actualiza $px1, $py1, $os
# en el bucle principal del original y se reinicia la secuencia Ghost.
sub _on_anchor_changed {
    my ($self, $event) = @_;
    $self->{confirmed_anchor} = {
        x   => $event->{index},
        y   => $event->{price},
        dir => $event->{direction},
    };
    # Al cambiar el ancla, el ghost anterior ya no es valido.
    # Equivale al comportamiento implicito de Pine: en la barra donde
    # se detecta el pivot, el bloque barstate.islast recalculara desde cero.
    $self->_publish_snapshot();
}


# =============================================================================
# _on_tick($event)
#
# TRANSCRIPCION DIRECTA del bloque barstate.islast del original.
# Orden de ejecucion IDENTICO al original (REGLA 2).
#
# El original ejecuta este bloque UNA VEZ en la ultima barra viva.
# Esta implementacion lo ejecuta en cada NewBarEvent para mantener
# el ghost actualizado en la arquitectura event-driven. El resultado
# matematico para la barra actual (la "ultima" en cada momento) es
# identico al que produce el original en barstate.islast.
# =============================================================================
sub _on_tick {
    my ($self, $event) = @_;

    return unless $event->{is_last};

    # Guardia show_miss: el bloque barstate.islast del original esta
    # enteramente dentro de if ($show_miss) { ... }
    return unless $self->{show_miss};

    my $index       = $event->{index};
    my $market_data = $event->{bar};

    # -------------------------------------------------------------------------
    # Paso 1: Leer px1, py1, os
    # Original: variables "var" globales persistentes $px1, $py1, $os
    # Aqui:     provienen del confirmed_anchor (emitido por AnchorResolver)
    # -------------------------------------------------------------------------
    my $anchor = $self->{confirmed_anchor};
    return unless $anchor;

    my $px1 = $anchor->{x};
    my $py1 = $anchor->{y};

    # Derivacion de os desde dir:
    #   dir == -1  => el ultimo pivot fue un High  => os = 1 (buscamos minimos)
    #   dir ==  1  => el ultimo pivot fue un Low   => os = 0 (buscamos maximos)
    # Identico al comportamiento de $os en el original.
    my $os = $anchor->{dir} == -1 ? 1 : 0;

    # Guardia de tramo minimo: si no existe al menos una barra despues del ancla,
    # el bucle del original seria: for (i=0; i<=b-px1-1; i++) con b-px1-1 < 0,
    # lo que no ejecutaria ninguna iteracion. Retornamos directamente.
    return if $index - $px1 <= 0;

    # -------------------------------------------------------------------------
    # Paso 2: Buscar x_last y y_last
    # Original:
    #   my @prices; my @prices_x;
    #   for (my $i = 0; $i <= $b - $px1 - 1; $i++) {
    #       my $val = $os == 1
    #           ? series_at($bars, $b, 'low',  $i)
    #           : series_at($bars, $b, 'high', $i);
    #       next unless defined $val;
    #       push @prices, $val; push @prices_x, $b - $i;
    #   }
    #   if ($os == 1) {
    #       $y_last = min(@prices);
    #       my ($idx) = grep { $prices[$_] == $y_last } 0 .. $#prices;
    #       $x_last = $prices_x[$idx];
    #   } else { ... max ... }
    # -------------------------------------------------------------------------
    my ($x_last, $y_last) = $self->_find_extreme($index, $market_data, $px1, $os);

    # Si el tramo no produjo ningun valor valido, no publicamos nada.
    # Equivale al if (scalar(@prices) > 0) del original.
    return unless defined $y_last;

    # -------------------------------------------------------------------------
    # Paso 3 & 4: Preparar ghost_line y ghost_label
    # Original:
    #   draw_line(x1=>$px1, y1=>$py1, x2=>$x_last, y2=>$y_last, color=>..., style=>'dashed')
    #   draw_label(x=>$x_last, y=>$y_last, text=>'ghost', color=>..., style=>...)
    #
    # ghost_dir: os==1 => linea baja (hacia minimo) => dir=1
    #             os==0 => linea sube (hacia maximo) => dir=-1
    # Identico a: $os == 1 ? $miss_ph_css : $miss_pl_css en el original
    # (el color depende de la direccion del movimiento esperado).
    # -------------------------------------------------------------------------
    my $ghost_dir = $os == 1 ? 1 : -1;

    # -------------------------------------------------------------------------
    # Paso 5: Reiniciar acumuladores Ghost VWAP
    # Original:
    #   my $ghost_cumVol = 0.0;
    #   my $ghost_cumPriceVol = 0.0;
    #   my $ghost_sumSqDiff = 0.0;
    # En el original estas son variables LOCALES al bloque barstate.islast,
    # lo que equivale a un reinicio total en cada ejecucion.
    # En _compute_ghost_vwap() se declaran como variables locales identicamente.
    # -------------------------------------------------------------------------

    # -------------------------------------------------------------------------
    # Paso 6: Calcular Ghost VWAP y todas las Bandas
    # Original:
    #   my $ghost_barsback = $b - $x_last;
    #   for (my $i = $ghost_barsback; $i >= 0; $i--) { ... }
    # -------------------------------------------------------------------------
    my $ghost_data = $self->_compute_ghost_vwap($x_last, $index, $market_data, $ghost_dir);

    # -------------------------------------------------------------------------
    # Paso 7: Publicar snapshot al StateCache
    # Original: draw_polyline(points=>$ghostVwapData->{points}, ...)
    #           generate_band_polylines($ghostBandsData)
    # -------------------------------------------------------------------------
    $self->_publish_snapshot($px1, $py1, $x_last, $y_last, $ghost_dir, $ghost_data);
}


# =============================================================================
# _find_extreme($index, $market_data, $px1, $os)
#
# TRANSCRIPCION del bucle de busqueda de extremo del original.
#
# CODIGO ORIGINAL REPRODUCIDO:
#   for (my $i = 0; $i <= $b - $px1 - 1; $i++) {
#       my $val = $os == 1
#           ? series_at($bars, $b, 'low',  $i)
#           : series_at($bars, $b, 'high', $i);
#       next unless defined $val;
#       push @prices,   $val;
#       push @prices_x, $b - $i;
#   }
#   if ($os == 1) {
#       $y_last = min(@prices);
#       my ($idx) = grep { $prices[$_] == $y_last } 0 .. $#prices;
#       $x_last  = $prices_x[$idx];
#   } else {
#       $y_last = max(@prices);
#       my ($idx) = grep { $prices[$_] == $y_last } 0 .. $#prices;
#       $x_last  = $prices_x[$idx];
#   }
#
# DIFERENCIA JUSTIFICADA (REGLA 4):
#   El original usa min()/max() + grep en dos pasadas sobre @prices.
#   Esta funcion reproduce el MISMO COMPORTAMIENTO OBSERVABLE en una sola
#   pasada mediante comparacion directa (< o >), sin funciones auxiliares.
#
#   La equivalencia en caso de empate es garantizada porque:
#     - El bucle itera $i = 0, 1, 2, ... (de mas reciente a mas antiguo)
#     - La comparacion estricta (< o >) NO actualiza en empate
#     - El PRIMER valor igual al extremo encontrado se retiene
#     - El PRIMER valor corresponde al $i mas pequeno (bar mas reciente)
#     - En el original: grep retorna el PRIMER indice de @prices donde
#       el valor iguala al min/max; @prices fue construido en orden
#       $i=0,1,2,... => primer indice == $i mas pequeno == bar mas reciente
#     => Comportamiento observable IDENTICO en caso de empate.
# =============================================================================
sub _find_extreme {
    my ($self, $index, $market_data, $px1, $os) = @_;

    my $x_last = undef;
    my $y_last = undef;

    # Replica exacta de: for (my $i = 0; $i <= $b - $px1 - 1; $i++)
    for (my $i = 0; $i <= $index - $px1 - 1; $i++) {

        # series_at($bars, $b, 'low',  $i) => $bars->[$b - $i]{low}
        # series_at($bars, $b, 'high', $i) => $bars->[$b - $i]{high}
        # Traduccion arquitectural: get_candle($index - $i)->{low|high}
        my $bar_idx = $index - $i;
        my $c = $market_data->get_candle($bar_idx);
        next unless $c;

        # Replica exacta de:
        #   my $val = $os == 1
        #       ? series_at($bars, $b, 'low',  $i)
        #       : series_at($bars, $b, 'high', $i);
        my $val = $os == 1 ? $c->{low} : $c->{high};
        next unless defined $val;

        # Replica del comportamiento de min()/max() + grep:
        # Comparacion directa, sin funciones auxiliares (REGLA 4).
        if ($os == 1) {
            # Replica: $y_last = min(@prices)
            # En empate, retiene el primero encontrado (i menor => bar mas reciente)
            if (!defined $y_last || $val < $y_last) {
                $y_last = $val;
                $x_last = $bar_idx;
            }
        } else {
            # Replica: $y_last = max(@prices)
            # En empate, retiene el primero encontrado (i menor => bar mas reciente)
            if (!defined $y_last || $val > $y_last) {
                $y_last = $val;
                $x_last = $bar_idx;
            }
        }
    }

    return ($x_last, $y_last);
}


# =============================================================================
# _compute_ghost_vwap($x_last, $index, $market_data, $ghost_dir)
#
# TRANSCRIPCION DIRECTA del bucle Ghost VWAP del original.
#
# CODIGO ORIGINAL REPRODUCIDO LINEA POR LINEA:
#   my $ghost_barsback = $b - $x_last;
#
#   my $ghost_cumVol      = 0.0;
#   my $ghost_cumPriceVol = 0.0;
#   my $ghost_sumSqDiff   = 0.0;
#
#   for (my $i = $ghost_barsback; $i >= 0; $i--) {
#       my $g_vol = series_at($bars, $b, 'volume', $i);
#       my $g_prc = series_at($bars, $b, 'src',    $i);
#       next unless defined $g_vol && defined $g_prc;
#
#       $ghost_cumVol      += $g_vol;
#       $ghost_cumPriceVol += $g_prc * $g_vol;
#       my $g_vwap = $ghost_cumVol > 0 ? $ghost_cumPriceVol / $ghost_cumVol : undef;
#
#       $ghost_sumSqDiff += $g_vol * (($g_prc - (defined($g_vwap)?$g_vwap:0)) ** 2);
#       my $g_stdDev = $ghost_cumVol > 0 ? sqrt($ghost_sumSqDiff / $ghost_cumVol) : 0.0;
#
#       my $ghost_bar_idx = $b - $i;
#       push @{$ghostVwapData->{points}},   chart_point_from_index($ghost_bar_idx, $g_vwap);
#       push @{$ghostBandsData->{u1_pts}},  chart_point_from_index($ghost_bar_idx, $g_vwap + $g_stdDev);
#       push @{$ghostBandsData->{l1_pts}},  chart_point_from_index($ghost_bar_idx, $g_vwap - $g_stdDev);
#       push @{$ghostBandsData->{u2_pts}},  chart_point_from_index($ghost_bar_idx, $g_vwap + 2*$g_stdDev);
#       push @{$ghostBandsData->{l2_pts}},  chart_point_from_index($ghost_bar_idx, $g_vwap - 2*$g_stdDev);
#       push @{$ghostBandsData->{u3_pts}},  chart_point_from_index($ghost_bar_idx, $g_vwap + 3*$g_stdDev);
#       push @{$ghostBandsData->{l3_pts}},  chart_point_from_index($ghost_bar_idx, $g_vwap - 3*$g_stdDev);
#   }
# =============================================================================
sub _compute_ghost_vwap {
    my ($self, $x_last, $index, $market_data, $ghost_dir) = @_;

    # Acumuladores locales: se crean en cada llamada, identico al original.
    # En el original son variables locales del bloque barstate.islast,
    # garantizando reinicio total en cada ejecucion del bloque.
    # REGLA 5: Prohibido mantener estado matematico entre eventos.
    my $ghost_cumVol      = 0.0;
    my $ghost_cumPriceVol = 0.0;
    my $ghost_sumSqDiff   = 0.0;

    # Arrays de puntos de salida.
    # Equivalen a ghostVwapData->{points} y ghostBandsData->{u1_pts,...}
    # del original. Se crean frescos en cada llamada (replica del clear del original).
    my @ghost_vwap_pts = ();
    my @bands_u1 = (); my @bands_l1 = ();
    my @bands_u2 = (); my @bands_l2 = ();
    my @bands_u3 = (); my @bands_l3 = ();

    # ghost_barsback = $b - $x_last  (identico al original)
    my $ghost_barsback = $index - $x_last;

    # Replica exacta de: for (my $i = $ghost_barsback; $i >= 0; $i--)
    for (my $i = $ghost_barsback; $i >= 0; $i--) {

        # series_at($bars, $b, 'volume', $i) => $bars->[$b - $i]{volume}
        # series_at($bars, $b, 'src',    $i) => $bars->[$b - $i]{src}
        # Traduccion arquitectural: get_candle($index - $i)->{volume}, _get_src_price
        my $bar_idx = $index - $i;
        my $c = $market_data->get_candle($bar_idx);
        next unless $c;

        my $g_vol = $c->{volume};
        my $g_prc = $self->_get_src_price($c);
        next unless defined $g_vol && defined $g_prc;

        # Acumulacion identica al original (copia literal de formulas):
        $ghost_cumVol      += $g_vol;
        $ghost_cumPriceVol += $g_prc * $g_vol;
        my $g_vwap = $ghost_cumVol > 0 ? $ghost_cumPriceVol / $ghost_cumVol : undef;

        $ghost_sumSqDiff += $g_vol * (($g_prc - (defined($g_vwap) ? $g_vwap : 0)) ** 2);
        $ghost_sumSqDiff = 0 if $ghost_sumSqDiff < 0;
        my $g_stdDev = $ghost_cumVol > 0 ? sqrt($ghost_sumSqDiff / $ghost_cumVol) : 0.0;

        # ghost_bar_idx = $b - $i  (identico al original)
        my $ghost_bar_idx = $index - $i;

        # chart_point_from_index(ghost_bar_idx, $g_vwap) => { x => .., y => .. }
        # Replica identica de cada push del original:
        push @ghost_vwap_pts, { x => $ghost_bar_idx, y => $g_vwap,               dir => $ghost_dir };
        push @bands_u1,       { x => $ghost_bar_idx, y => $g_vwap + $g_stdDev };
        push @bands_l1,       { x => $ghost_bar_idx, y => $g_vwap - $g_stdDev };
        push @bands_u2,       { x => $ghost_bar_idx, y => $g_vwap + 2 * $g_stdDev };
        push @bands_l2,       { x => $ghost_bar_idx, y => $g_vwap - 2 * $g_stdDev };
        push @bands_u3,       { x => $ghost_bar_idx, y => $g_vwap + 3 * $g_stdDev };
        push @bands_l3,       { x => $ghost_bar_idx, y => $g_vwap - 3 * $g_stdDev };
    }

    return {
        vwap_pts => \@ghost_vwap_pts,
        bands_u1 => \@bands_u1,  bands_l1 => \@bands_l1,
        bands_u2 => \@bands_u2,  bands_l2 => \@bands_l2,
        bands_u3 => \@bands_u3,  bands_l3 => \@bands_l3,
    };
}


# =============================================================================
# _publish_snapshot($px1, $py1, $x_last, $y_last, $ghost_dir, $ghost_data)
#
# Escribe los resultados calculados al StateCache.
# Equivale al conjunto de llamadas draw_line / draw_label / draw_polyline
# del original al final del bloque barstate.islast.
#
# Si se llama sin argumentos (reset), limpia el cache.
# =============================================================================
sub _publish_snapshot {
    my ($self, $px1, $py1, $x_last, $y_last, $ghost_dir, $ghost_data) = @_;
    my $c = $self->{cache};

    # Limpiar estado ghost anterior.
    # Equivale a delete_label($live_ghost_label) y delete_polyline al inicio
    # del bloque barstate.islast en el original.
    $c->clear_ghost();

    # ghost_path NO existe en el algoritmo original de LuxAlgo.
    # Se asigna undef (no array vacio) para fidelidad total (REGLA 6).
    $c->{ghost_path} = undef;

    # Si no hay datos calculados (llamada de reset o sin ancla), retornar.
    return unless defined $px1 && defined $x_last && defined $y_last;

    # -------------------------------------------------------------------------
    # ghost_line
    # Original: draw_line(x1=>$px1, y1=>$py1, x2=>$x_last, y2=>$y_last,
    #                     color=>($os==1 ? $miss_ph_css : $miss_pl_css), style=>'dashed')
    # -------------------------------------------------------------------------
    $c->{ghost_line} = {
        x1  => $px1,
        y1  => $py1,
        x2  => $x_last,
        y2  => $y_last,
        dir => $ghost_dir,
    };

    # -------------------------------------------------------------------------
    # ghost_label
    # Original: draw_label(x=>$x_last, y=>$y_last, text=>'ghost', color=>...,
    #                      style=>($os==1 ? 'label_up' : 'label_down'),
    #                      size=>'small', tooltip=>sprintf("%.4f", $y_last))
    # -------------------------------------------------------------------------
    $c->{ghost_label} = {
        x   => $x_last,
        y   => $y_last,
        dir => $ghost_dir,
    };

    # -------------------------------------------------------------------------
    # Ghost VWAP y Bandas
    # Original: draw_polyline(points=>$ghostVwapData->{points}, ...)
    #           generate_band_polylines($ghostBandsData)
    # -------------------------------------------------------------------------
    if ($ghost_data) {
        $c->{ghost_vwap}     = $ghost_data->{vwap_pts};
        $c->{ghost_bands_u1} = $ghost_data->{bands_u1};
        $c->{ghost_bands_l1} = $ghost_data->{bands_l1};
        $c->{ghost_bands_u2} = $ghost_data->{bands_u2};
        $c->{ghost_bands_l2} = $ghost_data->{bands_l2};
        $c->{ghost_bands_u3} = $ghost_data->{bands_u3};
        $c->{ghost_bands_l3} = $ghost_data->{bands_l3};
    }
}


# =============================================================================
# _get_src_price($candle)
# Equivale a src_price_at() del original. Sin cambios.
# Transcripcion de:
#   if    ($ps eq 'Close')  { return $bar->{close}; }
#   elsif ($ps eq 'OC2')    { return ($bar->{open} + $bar->{close}) / 2; }
#   elsif ($ps eq 'HLC3')   { return ($bar->{high} + $bar->{low} + $bar->{close}) / 3; }
#   elsif ($ps eq 'OHLC4')  { return ($bar->{open}+$bar->{high}+$bar->{low}+$bar->{close})/4;}
# =============================================================================
sub _get_src_price {
    my ($self, $candle) = @_;
    my $src_type = $self->{price_source};
    if    ($src_type eq 'Close') { return $candle->{close}; }
    elsif ($src_type eq 'OC2')   { return ($candle->{open} + $candle->{close}) / 2; }
    elsif ($src_type eq 'OHLC4') { return ($candle->{open} + $candle->{high} + $candle->{low} + $candle->{close}) / 4; }
    else                         { return ($candle->{high} + $candle->{low} + $candle->{close}) / 3; }
}

1;

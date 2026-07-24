package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::Interaction
# =============================================================================
# Interaccion: rueda, drag, pan, timeframe y reset de vista.
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

# _y_axis_scale_drag($mouse_y, $dy, $target)
sub _y_axis_scale_drag {
    my ($self, $mouse_y, $dy, $target) = @_;
    $target ||= 'price';

    if ($target eq 'atr') {
        $self->_atr_zoom_drag($mouse_y, $dy);
        return;
    }

    my $scale = $self->{price_scale};
    return unless $scale && defined $mouse_y && defined $dy && $dy != 0;

    $self->{auto_scale} = 0;
    # FIX-4c: el drag viene de la franja del eje Y; mouse_y es la coordenada Y
    # real del canvas, que puede estar dentro del rango 0..price_height. Si por
    # algun motivo queda fuera, la acotamos al centro del panel para que el ancla
    # del zoom sea estable y no cause un salto de rango.
    my $ph = $self->{price_height} || ($scale->{height} || 400);
    $mouse_y = $ph / 2 if $mouse_y < 0 || $mouse_y > $ph;

    # FIX-5: _ensure_scale_covers_data ya fue llamado en Button-1 al iniciar
    # el drag; no repetirlo en cada evento Motion para evitar el salto visual
    # en el primer pixel y el reencaje que revierte el zoom del usuario.
    Market::Core::VerticalScaleZoom::apply_drag(
        $scale, $mouse_y, $dy, $self->_vertical_zoom_opts('price'),
    );
    $scale->{scale_drag_active} = 1;
    $self->_request_render_throttled();
}

# _in_time_axis($y) -> bool
# Franja del eje de tiempo (debajo del ATR): zoom horizontal estilo TradingView.
sub _in_time_axis {
    my ($self, $y) = @_;
    return 0 unless defined $y;
    my $top = $self->_time_axis_y;
    my $h   = $self->{time_axis_height} || 42;
    return ($y >= $top && $y < $top + $h) ? 1 : 0;
}

# _route_wheel_zoom($dir, $ctrl)
# Enruta la rueda segun la zona bajo el cursor (estilo TradingView):
#   - Panel ATR          -> zoom vertical del ATR (escala propia, no precio).
#   - Eje Y de precios   -> zoom vertical del precio.
#   - Precio / eje tiempo -> zoom horizontal.
#   - Ctrl               -> zoom horizontal anclado al cursor.
sub _route_wheel_zoom {
    my ($self, $dir, $ctrl, $event_name, $seq, $dt) = @_;
    return unless defined $dir;

    # Resincroniza el tamano real ANTES de decidir la zona: evita el "salto
    # vertical" en Linux/X11 por <Configure> retrasado/incompleto.
    $self->_sync_canvas_geometry();

    my $x = $self->{crosshair_x};
    my $y = $self->{crosshair_y};
    my $canvas = $self->{canvas};
    my $canvas_w_before = eval { $canvas ? $canvas->width : undef };
    my $canvas_h_before = eval { $canvas ? $canvas->height : undef };
    my $price_strip_before = defined $x && defined $y ? ($self->_in_price_y_axis_strip($x, $y) ? 1 : 0) : 'undef';
    my $atr_strip_before = defined $x && defined $y ? ($self->_in_atr_y_axis_strip($x, $y) ? 1 : 0) : 'undef';
    $self->_dbg_wheel('ROUTE_CHECK',
        event        => $event_name,
        seq          => $seq,
        dt           => $dt,
        dir          => $dir,
        ctrl         => $ctrl ? 1 : 0,
        x            => $x,
        y            => $y,
        atr_strip    => $atr_strip_before,
        price_strip  => $price_strip_before,
        price_height => $self->{price_height},
        atr_height   => $self->{atr_height},
        strip_w      => $self->{price_scale}{y_axis_strip_w},
        width        => $self->{width},
        canvas_w     => $canvas_w_before,
        canvas_h     => $canvas_h_before,
    );
    my $before = {
        offset               => $self->{offset},
        current_visible_bars => $self->{current_visible_bars},
        x_shift              => $self->{x_shift},
        view_start           => $self->{view_start},
    };

    my $branch = 'horizontal';
    if ($ctrl) {
        $branch = 'horizontal_cursor';
        $self->_dbg_wheel('ROUTE',
            event  => $event_name,
            seq    => $seq,
            branch => $branch,
            dir    => $dir,
            ctrl   => 1,
        );
        $self->_horizontal_zoom_cursor($dir);
    }
    else {
        if (defined $x && defined $y && $self->_in_atr_y_axis_strip($x, $y)) {
            $branch = 'vertical_atr';
            $self->_dbg_wheel('ROUTE',
                event  => $event_name,
                seq    => $seq,
                branch => $branch,
                dir    => $dir,
                ctrl   => 0,
            );
            $self->_atr_zoom_wheel($dir);
        }
        elsif (defined $x && defined $y && $self->_in_price_y_axis_strip($x, $y)) {
            $branch = 'vertical_price';
            $self->_dbg_wheel('ROUTE',
                event  => $event_name,
                seq    => $seq,
                branch => $branch,
                dir    => $dir,
                ctrl   => 0,
            );
            $self->_vertical_zoom_scale($dir);
        }
        else {
            $branch = 'horizontal';
            $self->_dbg_wheel('ROUTE',
                event  => $event_name,
                seq    => $seq,
                branch => $branch,
                dir    => $dir,
                ctrl   => 0,
            );
            $self->_horizontal_zoom($dir);
        }
    }

    my $canvas_w_after = eval { $canvas ? $canvas->width : undef };
    my $canvas_h_after = eval { $canvas ? $canvas->height : undef };
    my $price_strip = defined $x && defined $y ? ($self->_in_price_y_axis_strip($x, $y) ? 1 : 0) : 'undef';
    my $atr_strip = defined $x && defined $y ? ($self->_in_atr_y_axis_strip($x, $y) ? 1 : 0) : 'undef';
    my $after = {
        offset               => $self->{offset},
        current_visible_bars => $self->{current_visible_bars},
        x_shift              => $self->{x_shift},
        view_start           => $self->{view_start},
    };

    if ($self->_wheel_debug_enabled()) {
        $self->_wheel_debug_log(sprintf(
            "WHEEL_ROUTE event=%s seq=%s dt=%s dir=%s ctrl=%s branch=%s x=%s y=%s crosshair=(%s,%s) canvas_before=(%s,%s) canvas_after=(%s,%s) self=(%s,%s) price_strip_before=%s atr_strip_before=%s price_strip_after=%s atr_strip_after=%s before{offset=%s visible=%s x_shift=%s view_start=%s} after{offset=%s visible=%s x_shift=%s view_start=%s}\n",
            defined $event_name ? $event_name : 'unknown',
            $self->_wheel_debug_value($seq),
            $self->_wheel_debug_value($dt),
            $self->_wheel_debug_value($dir),
            $ctrl ? 1 : 0,
            $branch,
            $self->_wheel_debug_value($x),
            $self->_wheel_debug_value($y),
            $self->_wheel_debug_value($self->{crosshair_x}),
            $self->_wheel_debug_value($self->{crosshair_y}),
            $self->_wheel_debug_value($canvas_w_before),
            $self->_wheel_debug_value($canvas_h_before),
            $self->_wheel_debug_value($canvas_w_after),
            $self->_wheel_debug_value($canvas_h_after),
            $self->_wheel_debug_value($self->{width}),
            $self->_wheel_debug_value($self->{height}),
            $price_strip_before,
            $atr_strip_before,
            $price_strip,
            $atr_strip,
            $self->_wheel_debug_value($before->{offset}),
            $self->_wheel_debug_value($before->{current_visible_bars}),
            $self->_wheel_debug_value($before->{x_shift}),
            $self->_wheel_debug_value($before->{view_start}),
            $self->_wheel_debug_value($after->{offset}),
            $self->_wheel_debug_value($after->{current_visible_bars}),
            $self->_wheel_debug_value($after->{x_shift}),
            $self->_wheel_debug_value($after->{view_start}),
        ));
    }
}

# _vertical_zoom_scale($dir) — solo precio (ATR usa ATRPanelZoom).
sub _vertical_zoom_scale {
    my ($self, $dir) = @_;
    return unless defined $dir;

    my $scale = $self->{price_scale};
    return unless $scale;

    $self->{auto_scale} = 0;

    my $y = $self->{crosshair_y};
    return unless defined $y;

    # FIX-4: si el cursor esta en la franja del eje Y (no en el area del grafico),
    # crosshair_y es una coordenada dentro de la franja (ancho ~66px) que NO
    # representa una posicion vertical util para anclar el zoom. En ese caso
    # usamos la coordenada Y real del cursor dentro del panel de precios, que es
    # la misma Y pero en coordenadas del canvas. Si ademas la Y cae fuera del
    # rango 0..price_height, la acotamos al centro del panel.
    my $ph = $self->{price_height} || 0;
    if ($y < 0 || $y > $ph) {
        $y = $ph / 2;
    }

    $self->_ensure_scale_covers_data('price');
    Market::Core::VerticalScaleZoom::apply_wheel(
        $scale, $y, $dir, $self->_vertical_zoom_opts('price'),
    );
    $self->request_render();
}

# _vertical_zoom($dir)
# $dir < 0 = zoom-in vertical  (velas mas grandes en Y, rango mas estrecho)
# $dir > 0 = zoom-out vertical (velas mas pequenas en Y, rango mas amplio)
# Desactiva auto-escala para que el efecto persista.
#
# Zoom anclado al cursor: el precio que esta bajo el cursor permanece a la
# misma altura de pantalla tras el zoom (estilo TradingView). Si el cursor no
# esta dentro del panel de precios, se ancla al centro (comportamiento previo).
sub _vertical_zoom {
    my ($self, $dir) = @_;
    $self->_vertical_zoom_scale($dir);
}

sub _scroll_offset {
    my ($self, $delta) = @_;
    return unless defined $delta;
    $self->{offset} += $delta;
    $self->compute_window();
    $self->request_render();
}

# _pan_price_range_by_pixels($dy) -> $changed
# Desplaza el rango Y de precios segun el movimiento vertical del cursor (px).
sub _pan_price_range_by_pixels {
    my ($self, $dy) = @_;
    return 0 unless defined $dy && $dy != 0;
    return 0 unless $self->{price_scale};

    my $scale = $self->{price_scale};
    my ($min, $max) = $scale->get_range();
    my $range = $max - $min;
    return 0 if $range <= 0;

    my $usable = $scale->{height}
               - $scale->{padding_top}
               - $scale->{padding_bottom};
    return 0 if $usable <= 0;

    my $shift = ($dy / $usable) * $range;
    $scale->set_range($min + $shift, $max + $shift);
    return 1;
}

# _pan_drag($dx, $dy, $allow_vertical)
# Desplazamiento del viewport. Boton izquierdo: solo horizontal. Boton derecho:
# horizontal + vertical. No cambia AUTO/MANUAL.
sub _pan_drag {
    my ($self, $dx, $dy, $allow_vertical, $accum_key) = @_;
    my $changed = 0;

    if ($allow_vertical && defined $dy && $dy != 0) {
        # En AUTO la escala Y la gobierna SIEMPRE el encaje automatico (estilo
        # TradingView): el pan vertical no aplica y no se "congela" la escala.
        # Para mover la Y a mano, cambia a MANUAL con la tecla 'a'.
        if (!$self->{auto_scale}) {
            $changed = 1 if $self->_pan_price_range_by_pixels($dy);
        }
    }

    # --- Horizontal (scroll por velas) ---
    if (defined $dx && $dx != 0) {
        my $cw = $self->{candle_width} || 1;
        $cw = 1 if $cw <= 0;
        $accum_key ||= ($allow_vertical ? 'rmb_drag_accum' : 'drag_accum');
        $self->{$accum_key} = ($self->{$accum_key} || 0) + $dx;
        my $bars = int($self->{$accum_key} / $cw);
        if ($bars != 0) {
            $self->{$accum_key} -= $bars * $cw;
            $self->{offset}     += $bars;
            $self->compute_window();
            $changed = 1;
        }
    }

    $self->_request_render_throttled() if $changed;
}

# ── Timeframe y vista ─────────────────────────────────────────────────────────

# _zoom_out_cap($total) -> $cap
# Tope de zoom-out para la temporalidad activa (misma regla en todas las TF).
sub _zoom_out_cap {
    my ($self, $total) = @_;
    return $self->{max_visible_bars} unless $total > 0;

    my $fit_all = int($total * 1.15) + 1;
    my $plot_w  = $self->_plot_width();
    my $cw_cap  = ($plot_w > 0)
                ? int($plot_w / 0.4)
                : ($self->{width} && $self->{width} > 0)
                    ? int($self->{width} / 0.4)
                    : $self->{max_visible_bars};
    my $cap = $fit_all > $cw_cap ? $fit_all : $cw_cap;
    return $self->{max_visible_bars} if $cap > $self->{max_visible_bars};
    return $cap;
}

# _default_visible_bars($total) -> $visible
sub _default_visible_bars {
    my ($self, $total) = @_;
    my $visible = $self->{initial_visible_bars};
    $visible = $self->{max_visible_bars} if $visible > $self->{max_visible_bars};
    $visible = $self->{min_visible_bars} if $visible < $self->{min_visible_bars};
    my $cap = $self->_zoom_out_cap($total);
    $visible = $cap if $visible > $cap;
    # TF con pocas velas: mostrarlas todas en pantalla (evita whitespace por defecto).
    $visible = $total if $total > 0 && $visible > $total;
    return $visible;
}

# _save_tf_viewport()
# Guarda offset/zoom/escala Y del TF activo antes de cambiar de temporalidad.
sub _save_tf_viewport {
    my ($self) = @_;
    my $tf = $self->{active_tf} || '1m';
    my $state = {
        offset               => $self->{offset},
        x_shift              => $self->{x_shift},
        current_visible_bars => $self->{current_visible_bars},
        _auto_y_frozen       => $self->{_auto_y_frozen} ? 1 : 0,
    };
    if (!$self->{auto_scale} && $self->{price_scale}) {
        my ($min, $max) = $self->{price_scale}->get_range();
        $state->{y_min} = $min if defined $min;
        $state->{y_max} = $max if defined $max;
    }
    $self->{tf_viewport}{$tf} = $state;
}

# _load_tf_viewport($tf)
# Restaura el viewport del TF o aplica defaults unificados en la primera visita.
sub _load_tf_viewport {
    my ($self, $tf) = @_;
    my $total = $self->{market_data} ? $self->{market_data}->size : 0;
    return unless $total > 0;

    my $saved = $self->{tf_viewport}{$tf};
    if ($saved) {
        $self->{offset}               = $saved->{offset};
        $self->{x_shift}              = $saved->{x_shift};
        $self->{current_visible_bars} = $saved->{current_visible_bars};
        $self->{_auto_y_frozen}       = $saved->{_auto_y_frozen} ? 1 : 0;
        if (!$self->{auto_scale} && $self->{price_scale}
            && defined $saved->{y_min} && defined $saved->{y_max}
            && $saved->{y_max} > $saved->{y_min})
        {
            $self->{price_scale}->set_range($saved->{y_min}, $saved->{y_max});
        }
    }
    else {
        $self->{offset}         = 0;
        $self->{x_shift}        = 0;
        $self->{_auto_y_frozen} = 0;
        $self->{current_visible_bars} = $self->_default_visible_bars($total);
        if (!$self->{auto_scale} && $self->{price_scale}) {
            my ($min_p, $max_p) = $self->_auto_scale_y_range(0, $total - 1);
            if (defined $min_p && defined $max_p && $max_p > $min_p) {
                my ($lo, $hi) = $self->_auto_scale_fit_range($min_p, $max_p);
                $self->{price_scale}->set_range($lo, $hi) if defined $lo && defined $hi;
            }
        }
    }

    $self->_sync_viewport_to_total();
}

# _sync_viewport_to_total()
# Acota visible/offset al total del TF activo y aplica limites horizontales.
sub _sync_viewport_to_total {
    my ($self) = @_;
    my $total = $self->{market_data} ? $self->{market_data}->size : 0;
    return unless $total > 0;

    my $visible = $self->{current_visible_bars} || $self->{initial_visible_bars};
    $visible = $self->{max_visible_bars} if $visible > $self->{max_visible_bars};
    $visible = $self->{min_visible_bars} if $visible < $self->{min_visible_bars};
    my $cap = $self->_zoom_out_cap($total);
    $visible = $cap if $visible > $cap;
    $self->{current_visible_bars} = $visible;

    my $pw = $self->_plot_width();
    $self->_apply_candle_width(($pw > 0 ? $pw : $self->{width}) / $visible);
    $self->compute_window();
}

sub set_timeframe {
    my ($self, $tf) = @_;
    return unless $self->{market_data};
    return unless Market::MarketData->tf_minutes($tf);

    $self->_replay_exit() if $self->{replay_controller} && $self->{replay_controller}->is_active();

    my $prev_tf = $self->{active_tf} || '1m';
    $self->_save_tf_viewport() if $prev_tf ne $tf;

    $self->{atr_auto_scale} = 1;

    if ($self->{timeframe_manager} && $self->{timeframe_manager}->can('apply')) {
        return unless $self->{timeframe_manager}->apply($self->{market_data}, $tf);
    }
    else {
        $self->{market_data}->set_timeframe($tf);
        return unless ($self->{market_data}->size || 0) > 0;
    }

    $self->{active_tf} = $tf;
    if ($self->{timeframe_manager} && $self->{timeframe_manager}->can('set_active')) {
        $self->{timeframe_manager}->set_active($tf);
    }
    $self->{indicator_manager}->rebuild_all($self->{market_data})
        if $self->{indicator_manager};

    # Cambio de timeframe = cambio del dataset activo: invalidar y reconstruir la
    # cache de analisis (una sola vez) antes de renderizar.
    $self->invalidate_analysis_cache();
    $self->rebuild_analysis_cache();

    $self->_load_tf_viewport($tf);
    $self->_sync_infra_state();
    $self->render();
    $self->_replay_sync_controls();
}

sub reset_view {
    my ($self) = @_;
    $self->_replay_exit() if $self->{replay_controller} && $self->{replay_controller}->is_active();
    $self->{tf_viewport}        = {};
    $self->{offset}             = 0;
    $self->{x_shift}            = 0;
    my $total = $self->{market_data} ? $self->{market_data}->size : 0;
    $self->{current_visible_bars} = $total > 0
        ? $self->_default_visible_bars($total)
        : $self->{initial_visible_bars};
    my $pw = $self->_plot_width();
    $self->_apply_candle_width(($pw > 0 ? $pw : $self->{width}) / $self->{current_visible_bars});
    $self->{auto_scale}     = 1;
    $self->{atr_auto_scale} = 1;
    $self->{_auto_y_frozen} = 0;
    $self->render();
}

sub _apply_candle_width {
    my ($self, $cw) = @_;
    return unless $cw && $cw > 0;
    $self->{candle_width}                = $cw;
    $self->{price_scale}->{candle_width} = $cw;
    $self->{atr_scale}->{candle_width}   = $cw;
}

sub _on_mouse_move {
    my ($self, $x, $y) = @_;
    return unless defined $x && defined $y;
    $self->{crosshair_x} = $x;
    $self->{crosshair_y} = $y;
    $self->_sync_infra_state();
    # Durante drag (escala o grafico) el motion ya hace render(); evitar parpadeo.
    return if $self->{y_axis_zoom_drag} || $self->{h_dragging} || $self->{rmb_dragging};
    $self->_draw_crosshair_all();
    $self->_draw_hud();
}

# _sync_canvas_geometry()
# Reconsulta el ancho/alto REAL del canvas (via winfo) y resincroniza el motor
# si difieren de los valores cacheados en $self->{width}/{height}. Existe
# porque en Linux/X11 el <Configure> puede llegar con retraso o en pasos
# intermedios mientras el WM termina de maximizar la ventana (en Windows no
# pasa esto). Si width/height quedan desfasados aunque sea por pocos pixeles,
# la franja del eje Y (width - strip_w) se corre hacia el area del grafico y
# un giro de rueda normal se clasifica por error como "zoom vertical".
# Se llama SIEMPRE antes de decidir la zona de un evento de rueda.
sub _sync_canvas_geometry {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    my $w = eval { $canvas->width  };
    my $h = eval { $canvas->height };
    return unless $w && $h && $w > 0 && $h > 0;
    $self->resize($w, $h) if $w != $self->{width} || $h != $self->{height};
}

1;

1;

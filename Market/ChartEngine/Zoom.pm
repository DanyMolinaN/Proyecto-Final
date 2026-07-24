package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::Zoom
# =============================================================================
# Zoom horizontal anclado (borde derecho / cursor).
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

sub _keep_candles_visible {
    my ($self) = @_;
    return;
}

# ── Zoom y desplazamiento ─────────────────────────────────────────────────────

# _next_visible_bars($current, $dir) -> $next
# Calcula el nuevo recuento de velas visibles para un paso de zoom, con paso
# minimo de +-1 vela (evita no-op por redondeo) y acotado a [min, max, total].
sub _next_visible_bars {
    my ($self, $current, $dir) = @_;
    my $total  = $self->{market_data}->size;
    # Paso del 20% por giro de rueda: recorre todo el rango (incluida la
    # compresion de TODA la data) en pocos giros, sin sentirse "pesado".
    my $factor = $dir < 0 ? 0.83 : 1.20;
    my $next   = int($current * $factor);
    if ($dir < 0) { $next = $current - 1 if $next >= $current; }  # zoom-in
    else          { $next = $current + 1 if $next <= $current; }  # zoom-out
    $next = $self->{min_visible_bars} if $next < $self->{min_visible_bars};
    $next = $self->{max_visible_bars} if $next > $self->{max_visible_bars};

    my $cap = $self->_zoom_out_cap($total);
    $next = $cap if $next > $cap;
    return $next;
}

# _last_visible_candle_index() -> $index | undef
# Ultima vela de DATOS cuyo cuerpo intersecta el area util del grafico (antes de la
# franja Y). NO total-1 global, NO el borde derecho del canvas, NO slots vacios
# (whitespace futuro a la derecha de la ultima vela pintada).
sub _last_visible_candle_index {
    my ($self) = @_;
    $self->compute_window();

    my $total = $self->{total_bars} || 0;
    return undef unless $total > 0;

    my $start = $self->{start_idx};
    my $end   = $self->{end_idx};
    return undef unless defined $end;

    my $strip  = $self->{price_scale}{y_axis_strip_w} || 66;
    my $plot_w = ($self->{width} || 0) - $strip;
    my $vstart = defined $self->{view_start} ? $self->{view_start} : 0;
    my $cw     = $self->{candle_width} || 1;
    my $xs     = $self->{x_shift} || 0;

    return $end if $plot_w <= 0 || $cw <= 0;

    my $lo = defined $start ? $start : 0;
    for (my $i = $end; $i >= $lo; $i--) {
        my $x_left  = (($i - $vstart) * $cw) + $xs;
        my $x_right = (($i + 1 - $vstart) * $cw) + $xs;
        return $i if $x_right > 0 && $x_left < $plot_w;
    }
    return $lo;
}

# _x_right_edge_of_index($index) -> $x
# Borde DERECHO del slot de la vela $index (misma formula que Scales/index_to_x + cw).
sub _x_right_edge_of_index {
    my ($self, $index) = @_;
    return 0 unless defined $index;
    my $vstart = defined $self->{view_start} ? $self->{view_start} : 0;
    my $xshift = $self->{x_shift} || 0;
    my $cw     = $self->{candle_width} || 1;
    return (($index + 1 - $vstart) * $cw) + $xshift;
}

# _set_anchor_x_shift($anchor_idx, $anchor_x, $cw, $right_edge)
# Calcula x_shift para mantener el ancla en anchor_x y lo acota a los limites
# horizontales. Nunca resetea a 0: si el offset se reclampa, compensa en x_shift.
sub _set_anchor_x_shift {
    my ($self, $anchor_idx, $anchor_x, $cw, $right_edge) = @_;
    return unless defined $anchor_idx && defined $anchor_x && $cw && $cw > 0;

    my $vstart = defined $self->{view_start} ? $self->{view_start} : 0;
    my $term   = $right_edge ? ($anchor_idx + 1 - $vstart) : ($anchor_idx - $vstart);
    $self->{x_shift} = $anchor_x - ($term * $cw);

    my $visible = $self->_normalized_visible_bars();
    my $total   = $self->{total_bars} || ($self->{market_data} ? $self->{market_data}->size : 0);
    return unless $total > 0 && $visible > 0;

    my ($min_o, $max_o) = $self->_horizontal_offset_limits($visible, $total);
    $self->_clamp_x_shift_horizontal($visible, $total, $min_o, $max_o);
}

# _zoom_render()
# Render del grafico durante zoom con tope de ~60fps (coalescing): una rueda
# rapida genera muchos notches; cada uno ya actualizo el estado del viewport, por
# lo que basta UN render por frame con el ultimo estado. Difiere el HUD para
# evitar parpadeos. El flag _zoom_frame omite el HUD dentro de render().
sub _zoom_render {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    return if $self->{pending};
    $self->{pending} = 1;
    $canvas->after(16, sub {
        $self->{pending}     = 0;
        $self->{_zoom_frame} = 1;
        $self->render();
        delete $self->{_zoom_frame};

        $canvas->afterCancel($self->{_zoom_hud_after}) if $self->{_zoom_hud_after};
        $self->{_zoom_hud_after} = $canvas->after(40, sub {
            delete $self->{_zoom_hud_after};
            $self->_draw_hud();
        });
    });
}

# _zoom_keep_right_edge($next, $anchor_idx, $anchor_x)
# Rueda: ancla = ultima vela visible (p. ej. 500 en 300..500). Conserva
# end_visual (offset derivado) y whitespace; solo cambia visible_bars,
# candle_width y x_shift sub-pixel.
sub _zoom_keep_right_edge {
    my ($self, $next, $anchor_idx, $anchor_x) = @_;
    return unless $next && $next > 0;
    return unless defined $anchor_idx && defined $anchor_x;

    my $total = $self->{market_data}->size;
    return unless $total > 0;

    my $offset_before = $self->{offset} || 0;
    my $end_visual    = $total - 1 - $offset_before;

    $self->{current_visible_bars} = $next;
    my $pw = $self->_plot_width();
    my $cw_new = ($pw > 0 ? $pw : $self->{width}) / $next;
    $cw_new = 1 if $cw_new <= 0;
    $self->_apply_candle_width($cw_new);

    # Mantener end_visual estable; reclampar offset solo si los limites lo exigen.
    my ($min_o, $max_o) = $self->_horizontal_offset_limits($next, $total);
    my $off = $total - 1 - $end_visual;
    $off = $min_o if $off < $min_o;
    $off = $max_o if $off > $max_o;
    $self->{offset} = $off;

    $self->compute_window();
    $self->_set_anchor_x_shift($anchor_idx, $anchor_x, $cw_new, 1);
    $self->_zoom_render();
}

# _zoom_keep_anchor($next, $idx_anchor, $anchor_x)
# Aplica el nuevo recuento de velas ($next) manteniendo el indice CONTINUO
# $idx_anchor fijo en la coordenada de pantalla $anchor_x.
#
# Precision tipo TradingView: el offset se mantiene entero (la ventana de datos
# avanza por velas), pero el residuo sub-pixel se absorbe en x_shift, calculado
# de forma EXACTA tras acotar la ventana. Asi el ancla no se mueve ni acumula
# desfase entre zooms sucesivos. Solo toca el eje X (no la escala Y), por lo que
# se comporta igual en modo automatico y manual.
sub _zoom_keep_anchor {
    my ($self, $next, $idx_anchor, $anchor_x) = @_;
    my $total = $self->{market_data}->size;
    return unless $total > 0 && $next && $next > 0;

    $self->{current_visible_bars} = $next;
    my $pw = $self->_plot_width();
    my $cw_new = ($pw > 0 ? $pw : $self->{width}) / $next;
    $cw_new = 1 if $cw_new <= 0;
    $self->_apply_candle_width($cw_new);

    # view_start objetivo (indice logico del borde izquierdo) que deja el ancla lo
    # mas cerca posible de anchor_x; de ahi el offset entero correspondiente.
    my $start_float   = $idx_anchor - ($anchor_x / $cw_new);
    my $start_tgt     = $self->round($start_float);
    my $offset_target = $total - $next - $start_tgt;
    $self->{offset}   = $offset_target;

    # compute_window acota offset/visible a los limites validos -> view_start real.
    $self->compute_window();
    $self->_set_anchor_x_shift($idx_anchor, $anchor_x, $cw_new, 0);
    $self->_zoom_render();
}

# _horizontal_zoom($dir)  ->  rueda del mouse
# $dir < 0 = zoom-in   $dir > 0 = zoom-out
#
# ANCLAJE: ultima vela visible en el viewport (p. ej. 500 en 300..500 o con
# whitespace a su derecha). Zoom hacia la izquierda; borde derecho de esa vela
# fijo en pixeles (x_shift sub-pixel, sin deriva acumulativa).
sub _horizontal_zoom {
    my ($self, $dir) = @_;
    return unless defined $dir;

    my $current = $self->{current_visible_bars} || $self->{initial_visible_bars};
    return unless $self->{market_data} && $self->{market_data}->size > 0;

    my $next = $self->_next_visible_bars($current, $dir);
    return if $next == $current;   # no-op solo en los limites reales

    my $anchor_idx = $self->_last_visible_candle_index();
    return unless defined $anchor_idx;

    my $anchor_x = $self->_x_right_edge_of_index($anchor_idx);
    $self->_zoom_keep_right_edge($next, $anchor_idx, $anchor_x);
}

# _horizontal_zoom_cursor($dir)  ->  CTRL + rueda del mouse
# $dir < 0 = zoom-in   $dir > 0 = zoom-out
#
# ANCLAJE A LA X DEL CURSOR (rueda libre estilo TradingView): el indice/timestamp
# alineado con la columna vertical del cursor permanece EXACTAMENTE en la misma X
# durante el zoom. La Y del cursor NO influye y el cursor no necesita estar sobre
# una vela concreta (se ancla la posicion horizontal continua).
sub _horizontal_zoom_cursor {
    my ($self, $dir) = @_;
    return unless defined $dir;

    my $anchor_x = $self->{crosshair_x};
    return $self->_horizontal_zoom($dir) unless defined $anchor_x;

    my $current = $self->{current_visible_bars} || $self->{initial_visible_bars};
    my $total   = $self->{market_data}->size;
    return unless $total > 0;

    my $next = $self->_next_visible_bars($current, $dir);
    return if $next == $current;

    # Indice CONTINUO bajo el cursor con el mapeo X actual (incluye x_shift).
    my $cw_old     = $self->{candle_width} || ($self->{width} / $current);
    my $start_old  = defined $self->{view_start} ? $self->{view_start} : 0;
    my $xshift     = $self->{x_shift} || 0;
    my $idx_anchor = (($anchor_x - $xshift) / $cw_old) + $start_old;

    $self->_zoom_keep_anchor($next, $idx_anchor, $anchor_x);
}


1;

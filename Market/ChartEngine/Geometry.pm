package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::Geometry
# =============================================================================
# Geometria del viewport, escalas Y/ATR y compute_window.
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

# _min_edge_bars($total) -> $keep
# Velas minimas que deben permanecer visibles en cada extremo de navegacion.
sub _min_edge_bars {
    my ($self, $total) = @_;
    my $keep = $self->{min_edge_bars} || 2;
    return $total if $total > 0 && $keep > $total;
    return $keep;
}

# _normalized_visible_bars() -> $visible
sub _normalized_visible_bars {
    my ($self) = @_;
    my $visible = $self->{current_visible_bars} || $self->{initial_visible_bars};
    $visible = $self->{max_visible_bars} if $visible > $self->{max_visible_bars};
    $visible = $self->{min_visible_bars} if $visible < $self->{min_visible_bars};
    return $visible;
}

# _plot_width() -> px
# Ancho util del area de velas (sin franja del eje Y).
sub _plot_width {
    my ($self) = @_;
    my $strip = $self->{price_scale}{y_axis_strip_w} || 66;
    my $w     = ($self->{width} || 0) - $strip;
    return $w > 0 ? $w : 0;
}

# _max_draw_bars() -> $n
# Tope de velas a dibujar por frame (evita miles de objetos Tk en zoom-out).
sub _max_draw_bars {
    my ($self) = @_;
    my $pw = $self->_plot_width();
    return 1200 if $pw <= 0;
    return int($pw * 2) + 4;
}

# _update_y_data_cache($start, $end, [$vatr])
# Guarda min/max de datos visibles para acotar el zoom vertical manual.
sub _update_y_data_cache {
    my ($self, $start, $end, $vatr) = @_;
    if (defined $start && defined $end && $end >= $start) {
        my @pr = $self->_auto_scale_y_range($start, $end);
        $self->{_cached_price_y} = \@pr if @pr == 2 && $pr[1] > $pr[0];
    }
    return unless $vatr && ref $vatr eq 'ARRAY' && @$vatr;

    my ($lo, $hi);
    for my $v (@$vatr) {
        next unless defined $v;
        $lo = $v if !defined $lo || $v < $lo;
        $hi = $v if !defined $hi || $v > $hi;
    }
    $self->{_cached_atr_y} = [$lo, $hi]
        if defined $lo && defined $hi && $hi >= $lo;
}

# _atr_zoom_opts() -> \%opts
sub _atr_zoom_opts {
    my ($self) = @_;
    my %opts = (panel_height => $self->{atr_height});
    if ($self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2) {
        @opts{qw(data_min data_max)} = @{$self->{_cached_atr_y}};
    }
    return \%opts;
}

# _atr_zoom_wheel($dir)
sub _atr_zoom_wheel {
    my ($self, $dir) = @_;
    return unless defined $dir;
    return unless $self->{atr_scale};
    return unless $self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2;

    my $ph  = $self->{price_height} || 0;
    my $ah  = $self->{atr_height}   || 110;
    my $y   = $self->{crosshair_y};

    # FIX-4b: si el cursor esta en la franja del eje Y del ATR, la Y puede
    # estar fuera del rango valido del panel ATR (ph..ph+ah). Acotamos al
    # centro del panel ATR para que el ancla del zoom sea estable.
    if (!defined $y || $y < $ph || $y > $ph + $ah) {
        $y = $ph + $ah / 2;
    }

    $self->{atr_auto_scale} = 0;
    Market::Core::ATRPanelZoom::apply_wheel_at_y(
        $self->{atr_scale}, $y, $dir, $self->_atr_zoom_opts(),
    );
    $self->request_render();
}

# _atr_zoom_drag($mouse_y, $dy)
sub _atr_zoom_drag {
    my ($self, $mouse_y, $dy) = @_;
    return unless defined $mouse_y && defined $dy && $dy != 0;
    return unless $self->{atr_scale};
    return unless $self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2;

    $self->{atr_auto_scale} = 0;
    Market::Core::ATRPanelZoom::apply_drag_at_y(
        $self->{atr_scale}, $mouse_y, $dy, $self->_atr_zoom_opts(),
    );
    $self->{atr_scale}->{scale_drag_active} = 1;
    $self->_request_render_throttled();
}

# _vertical_zoom_opts($target) -> \%opts
sub _vertical_zoom_opts {
    my ($self, $target) = @_;
    my %opts;
    if ($target eq 'atr') {
        $opts{panel_height}   = $self->{atr_height};
        $opts{min_span_ratio} = 0.10;
        $opts{max_span_ratio} = 4.0;
        if ($self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2) {
            @opts{qw(data_min data_max)} = @{$self->{_cached_atr_y}};
        }
    }
    else {
        $opts{panel_height} = $self->{price_height};
        if ($self->{_cached_price_y} && @{$self->{_cached_price_y}} == 2) {
            @opts{qw(data_min data_max)} = @{$self->{_cached_price_y}};
        }
        else {
            # FIX-3b: cache de precio vacia (primer zoom antes del primer render).
            # Calculamos el rango en caliente para que _bound_range tenga limites
            # y no dispare el rango de la escala a valores absurdos.
            my $s = $self->{start_idx} // 0;
            my $e = $self->{end_idx};
            if (defined $e && $e >= $s) {
                my ($mn, $mx) = $self->_auto_scale_y_range($s, $e);
                if (defined $mn && defined $mx && $mx > $mn) {
                    $opts{data_min} = $mn;
                    $opts{data_max} = $mx;
                    # Guardamos en cache para los eventos Motion subsiguientes.
                    $self->{_cached_price_y} = [$mn, $mx];
                }
            }
        }
    }
    return \%opts;
}

# _ensure_scale_covers_data($target)
# Si el rango manual dejo los datos fuera, reencaja antes de zoom.
sub _ensure_scale_covers_data {
    my ($self, $target) = @_;
    my $scale = $target eq 'atr' ? $self->{atr_scale} : $self->{price_scale};
    return unless $scale;

    my $opts = $self->_vertical_zoom_opts($target);
    return unless defined $opts->{data_min} && defined $opts->{data_max};

    my ($min, $max) = $scale->get_range();
    my $lo = $opts->{data_min};
    my $hi = $opts->{data_max};
    return if $max >= $lo && $min <= $hi;

    Market::Core::VerticalScaleZoom::fit_to_data(
        $scale, $lo, $hi,
        { padding_ratio => $target eq 'atr' ? 0.10 : 0.06 },
    );
}

# _repair_manual_scale_if_data_outside($target)
# En MANUAL no reencajar la escala en cada frame: eso anula pan y zoom vertical.
# Solo recuperar si los datos visibles quedaron totalmente fuera del rango Y.
sub _repair_manual_scale_if_data_outside {
    my ($self, $target) = @_;
    $target ||= 'price';

    if ($target eq 'atr') {
        return if $self->{atr_auto_scale};
        my $scale = $self->{atr_scale};
        return unless $scale;
        return unless $self->{_cached_atr_y} && @{$self->{_cached_atr_y}} == 2;
        my ($lo, $hi) = @{$self->{_cached_atr_y}};
        my ($min, $max) = $scale->get_range();
        return unless defined $min && defined $max && $max > $min;
        return if $max >= $lo && $min <= $hi;
        Market::Core::ATRPanelZoom::fit_to_data(
            $scale, $lo, $hi, { padding_ratio => 0.10 },
        );
        return;
    }

    return if $self->{auto_scale};
    my $scale = $self->{price_scale};
    return unless $scale;
    return unless $self->{_cached_price_y} && @{$self->{_cached_price_y}} == 2;
    my ($lo, $hi) = @{$self->{_cached_price_y}};
    my ($min, $max) = $scale->get_range();
    return unless defined $min && defined $max && $max > $min;
    return if $max >= $lo && $min <= $hi;
    Market::Core::VerticalScaleZoom::fit_to_data(
        $scale, $lo, $hi, { padding_ratio => 0.06 },
    );
}

# _auto_scale_y_range($s_start, $s_end) -> ($min, $max)
# Rango Y para auto-escala con muestreo si el tramo es muy largo.
sub _auto_scale_y_range {
    my ($self, $s_start, $s_end) = @_;
    return unless $self->{market_data};
    return unless defined $s_start && defined $s_end && $s_end >= $s_start;

    my $cap = 600;
    my $n   = $s_end - $s_start + 1;
    if ($n <= $cap) {
        my $slice = $self->{market_data}->get_slice($s_start, $s_end);
        return $self->{price_panel}->get_y_range($slice) if $slice && @$slice;
        return;
    }

    my $stride = int($n / $cap) + 1;
    my ($min_p, $max_p);
    for (my $i = $s_start; $i <= $s_end; $i += $stride) {
        my $c = $self->{market_data}->get_candle($i);
        next unless $c && defined $c->{low} && defined $c->{high};
        $min_p = $c->{low}  if !defined $min_p || $c->{low}  < $min_p;
        $max_p = $c->{high} if !defined $max_p || $c->{high} > $max_p;
    }
    my $last = $self->{market_data}->get_candle($s_end);
    if ($last && defined $last->{low} && defined $last->{high}) {
        $min_p = $last->{low}  if !defined $min_p || $last->{low}  < $min_p;
        $max_p = $last->{high} if !defined $max_p || $last->{high} > $max_p;
    }
    return ($min_p, $max_p);
}

# _auto_scale_fit_range($min_p, $max_p) -> ($lo, $hi)
# Expande el rango OHLC con padding en PIXELES para que etiquetas SMC
# (HH/LL/SH/SL/BOS) y la banda de volumen queden visibles en modo AUTO.
# El 4% fijo anterior era insuficiente: las etiquetas caian fuera del panel.
sub _auto_scale_fit_range {
    my ($self, $min_p, $max_p) = @_;
    return unless defined $min_p && defined $max_p && $max_p > $min_p;

    my $scale = $self->{price_scale};
    my $h  = ($scale && $scale->{height}) || $self->{price_height} || 400;
    my $pt = ($scale && $scale->{padding_top})    || 20;
    my $pb = ($scale && $scale->{padding_bottom}) || 20;
    my $usable = $h - $pt - $pb;
    $usable = 120 if $usable < 120;

    # Espacio encima de maximos (HH/SH apilados) y debajo de minimos
    # (LL/SL + zona de volumen ~15% del panel util).
    my $top_px = 40;
    my $bot_px = 32 + int($usable * 0.15);
    my $need   = $top_px + $bot_px;
    my $max_reserve = int($usable * 0.42);
    if ($need > $max_reserve && $need > 0) {
        my $f = $max_reserve / $need;
        $top_px = int($top_px * $f);
        $bot_px = $max_reserve - $top_px;
    }

    my $R = $max_p - $min_p;
    my $denom = $usable - $top_px - $bot_px;
    $denom = int($usable * 0.58) if $denom < $usable * 0.5;
    $denom = 1 if $denom < 1;

    # total_price_span T tal que top_px/bot_px ocupen exactamente esos pixeles.
    my $T       = $R * $usable / $denom;
    my $top_pad = $T * ($top_px / $usable);
    my $bot_pad = $T * ($bot_px / $usable);
    $top_pad = $R * 0.04 if $top_pad <= 0;
    $bot_pad = $R * 0.04 if $bot_pad <= 0;

    return ($min_p - $bot_pad, $max_p + $top_pad);
}

# _prepare_draw_slice($draw_start, $draw_end) -> ($slice, $first_index, $stride)
# Evita copiar/decimar en el panel cuando hay decenas de miles de velas.
sub _prepare_draw_slice {
    my ($self, $ds, $de) = @_;
    return ([], $ds, 1) unless $self->{market_data};
    return ([], $ds, 1) unless defined $ds && defined $de && $de >= $ds;

    my $max = $self->_max_draw_bars();
    my $n   = $de - $ds + 1;
    if ($n <= $max) {
        my $slice = $self->{market_data}->get_slice($ds, $de);
        return ($slice, $ds, 1);
    }

    my $stride = int($n / $max) + 1;
    my @out;
    for (my $i = $ds; $i <= $de; $i += $stride) {
        my $c = $self->{market_data}->get_candle($i);
        push @out, $c if $c;
    }
    my $last = $self->{market_data}->get_candle($de);
    if ($last && (!@out || $out[-1] != $last)) {
        push @out, $last;
    }
    return (\@out, $ds, $stride);
}

# _horizontal_offset_limits($visible, $total) -> ($min_offset, $max_offset)
# Unica fuente de verdad para los topes de scroll horizontal (offset entero).
#
# Geometria: view_start = total - visible - offset; end_visual = total-1-offset.
#   - offset = 0: vista reciente (ultima vela anclada a la derecha del viewport).
#   - offset = total - visible: vista historica (barra 0 al borde izquierdo util).
#   - offset = keep - visible: extremo futuro (keep ultimas velas + whitespace).
#
# Con visible > total el historico queda en offset negativo (total-visible); el
# tope superior del rango sigue siendo offset=0 (reciente), no el historico.
sub _horizontal_offset_limits {
    my ($self, $visible, $total) = @_;
    return (0, 0) unless $total > 0 && $visible > 0;

    my $keep       = $self->_min_edge_bars($total);
    my $min_offset = $keep - $visible;
    $min_offset = 0 if $min_offset > 0;
    my $max_offset = $total - $visible;
    $max_offset = 0 if $max_offset < 0;
    return ($min_offset, $max_offset);
}

# _offset_at_historical_extreme($visible, $total) -> $offset
sub _offset_at_historical_extreme {
    my ($self, $visible, $total) = @_;
    return 0 unless $total > 0 && $visible > 0;
    return $total - $visible;
}

# _offset_at_future_extreme($visible, $total) -> $offset
sub _offset_at_future_extreme {
    my ($self, $visible, $total) = @_;
    return 0 unless $total > 0 && $visible > 0;
    my ($min_offset) = $self->_horizontal_offset_limits($visible, $total);
    return $min_offset;
}

# _enforce_horizontal_offset($visible, $total) -> $clamped
# Acota offset a los limites. Debe invocarse tras CUALQUIER cambio de offset,
# visible_bars o candle_width (via compute_window).
sub _enforce_horizontal_offset {
    my ($self, $visible, $total) = @_;
    $self->{offset} = 0 unless defined $self->{offset};
    return 0 unless $total > 0 && $visible > 0;

    my ($min_o, $max_o) = $self->_horizontal_offset_limits($visible, $total);
    my $before = $self->{offset};
    $self->{offset} = $min_o if $self->{offset} < $min_o;
    $self->{offset} = $max_o if $self->{offset} > $max_o;
    return ($before != $self->{offset}) ? 1 : 0;
}

# _clamp_x_shift_horizontal($visible, $total, $min_offset, $max_offset)
# Acota x_shift para que en los extremos queden `keep` velas ancladas al borde
# correcto (historico = izquierda, futuro = derecha), con whitespace opuesto.
sub _clamp_x_shift_horizontal {
    my ($self, $visible, $total, $min_offset, $max_offset) = @_;
    return unless $total > 0 && $visible > 0;

    my $cw = $self->{candle_width} || 1;
    return if $cw <= 0;

    my $plot_w = $self->_plot_width();
    return if $plot_w <= 0;

    my $keep = $self->_min_edge_bars($total);
    my $off  = $self->{offset};
    my $end_visual = $total - 1 - $off;
    my $vstart     = $end_visual - $visible + 1;
    my $xs         = $self->{x_shift} || 0;

    my $hist_off = $self->_offset_at_historical_extreme($visible, $total);
    my $at_historical = ($visible > $total)
        ? ($off <= $hist_off + 1e-9)
        : ($off >= $hist_off - 1e-9);
    my $at_future = ($off <= $min_offset + 1e-9);

    if ($at_historical) {
        # Extremo historico: las `keep` velas mas antiguas pegadas a la IZQUIERDA.
        # vstart=0 (visible<=total) o vstart negativo con zoom-out (visible>total).
        my $first_slot = 0 - $vstart;          # slot donde cae la barra 0
        $first_slot = 0 if $first_slot < 0;
        my $min_xs = 0.01 - $first_slot * $cw; # barra 0 no sale por la izquierda
        my $max_xs = $plot_w - $keep * $cw - 0.01 - $first_slot * $cw;
        if ($max_xs < $min_xs) {
            $xs = $min_xs;
        }
        else {
            $xs = $min_xs if $xs < $min_xs;
            $xs = $max_xs if $xs > $max_xs;
        }
    }
    elsif ($at_future) {
        # Extremo futuro: las `keep` velas mas recientes pegadas a la DERECHA.
        # vstart = total - keep; x_shift positivo las empuja a slots derechos.
        my $canonical = ($visible - $keep) * $cw;
        my $last_slot = ($total - 1) - $vstart;
        my $min_xs = 0.01;
        my $max_xs = $plot_w - ($last_slot + 1) * $cw - 0.01;
        if ($max_xs < $min_xs) {
            $xs = $canonical;
        }
        else {
            # Preferir anclaje derecho; permitir pan fino hacia la izquierda.
            $xs = $canonical if abs($xs) < 1e-6 && $max_xs >= $canonical;
            $xs = $min_xs if $xs < $min_xs;
            $xs = $max_xs if $xs > $max_xs;
        }
    }
    else {
        # Posicion intermedia: al menos una vela del tramo de datos en pantalla.
        my $lo = $self->{start_idx};
        my $hi = $self->{end_idx};
        if (defined $lo && defined $hi && $hi >= $lo) {
            my $min_xs = -($lo - $vstart) * $cw + 0.01;
            my $max_xs = $plot_w - ($hi - $vstart) * $cw - 0.01;
            if ($min_xs <= $max_xs) {
                $xs = $min_xs if $xs < $min_xs;
                $xs = $max_xs if $xs > $max_xs;
            }
        }
    }

    $self->{x_shift} = $xs;
}

sub compute_window {
    my ($self) = @_;
    my $total = $self->{market_data}->size;
    $self->{total_bars} = $total;
    return (0, 0) unless $total > 0;

    my $visible = $self->_normalized_visible_bars();
    # NO se acota $visible a $total: zoom-out "mas alla de la data" (TradingView).

    # Durante replay, TODO el calculo de offset/limites/anclaje debe operar
    # sobre el universo "visible hasta el puntero" (eff_total), no sobre el
    # total real de velas. Antes se calculaba con $total y solo se recortaba
    # $data_end al limite de replay al final: eso dejaba a `offset` y a
    # `_clamp_x_shift_horizontal` razonando sobre un extremo "futuro" que no
    # es real (el ultimo dato del dataset) en lugar del extremo del replay
    # (el indice actual del puntero). El sintoma visible era el desanclaje /
    # corrimiento de las velas al reproducir cerca del inicio de la data o al
    # acercarse al puntero de replay.
    my $replay_limit;
    if ($self->{replay_controller} && $self->{replay_controller}->can('visible_limit')
        && $self->{replay_controller}->{enabled})
    {
        $replay_limit = $self->{replay_controller}->visible_limit($total);
    }
    my $eff_total = (defined $replay_limit) ? ($replay_limit + 1) : $total;
    $eff_total = 1 if $eff_total < 1;

    my ($min_offset, $max_offset) = $self->_horizontal_offset_limits($visible, $eff_total);
    $self->_enforce_horizontal_offset($visible, $eff_total);

    # end_visual puede superar eff_total-1: esos "slots" sobrantes son el
    # whitespace (a la derecha del puntero de replay, o del ultimo dato real).
    my $end_visual = $eff_total - 1 - $self->{offset};
    my $start      = $end_visual - $visible + 1;

    $self->{view_start} = $start;

    my $data_start = $start;      $data_start = 0            if $data_start < 0;
    my $data_end   = $end_visual; $data_end   = $eff_total - 1 if $data_end > $eff_total - 1;
    $data_end = 0 if $data_end < 0;

    $self->{visible_bars} = $data_end - $data_start + 1;
    $self->{start_idx}    = $data_start;
    $self->{end_idx}      = $data_end;

    $self->_clamp_x_shift_horizontal($visible, $eff_total, $min_offset, $max_offset);
    $self->_sync_infra_state();

    return ($data_start, $data_end);
}

# ── Render ────────────────────────────────────────────────────────────────────


1;

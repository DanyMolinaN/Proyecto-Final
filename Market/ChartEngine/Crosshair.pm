package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::Crosshair
# =============================================================================
# Hit-test de paneles, crosshair, HUD y etiquetas de tiempo.
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

sub _in_price_panel {
    my ($self, $y) = @_;
    return 0 unless defined $y;
    my $ph = $self->{price_height} || 0;
    return ($y >= 0 && $y <= $ph) ? 1 : 0;
}

# _in_price_y_axis_strip($x, $y) -> bool
# Verdadero si el cursor esta sobre la franja del eje Y de precios (derecha).
sub _in_price_y_axis_strip {
    my ($self, $x, $y) = @_;
    return Market::Core::YAxisHitTest::in_y_axis_strip(
        $x, $y,
        width     => $self->{width} || 0,
        strip_w   => $self->{price_scale}{y_axis_strip_w} || 66,
        y_top     => 0,
        y_bottom  => $self->{price_height} || 0,
    );
}

# _in_atr_y_axis_strip($x, $y) -> bool
sub _in_atr_y_axis_strip {
    my ($self, $x, $y) = @_;
    my $ph = $self->{price_height} || 0;
    return Market::Core::YAxisHitTest::in_y_axis_strip(
        $x, $y,
        width     => $self->{width} || 0,
        strip_w   => $self->{atr_scale}{y_axis_strip_w} || 66,
        y_top     => $ph,
        y_bottom  => $ph + ($self->{atr_height} || 0),
    );
}

# _hide_crosshair_all()
# Oculta todo el crosshair (estilo TradingView al entrar en la escala de precios).
sub _hide_crosshair_all {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    $self->{price_panel}->hide_crosshair($canvas) if $self->{price_panel};
    $canvas->delete('atr_crosshair');
}

# _draw_crosshair_all()
# Dibuja el crosshair en todos los paneles con SNAP a la vela bajo el cursor:
# la linea vertical, la fecha y el OHLC usan el centro de esa vela y quedan
# perfectamente alineados. En la zona de whitespace (a la derecha de la ultima
# vela) la linea sigue libremente al cursor y la fecha se oculta.
# ESCALAY: sobre la franja del eje Y de precios no se muestra crosshair ni OHLC.
sub _draw_crosshair_all {
    my ($self) = @_;
    return unless defined $self->{crosshair_x};
    my $canvas = $self->{canvas};
    my $x = $self->{crosshair_x};
    my $y = $self->{crosshair_y} || 0;

    if ($self->_in_price_y_axis_strip($x, $y) || $self->_in_atr_y_axis_strip($x, $y)) {
        $self->{crosshair_idx} = undef;
        $self->_hide_crosshair_all();
        return;
    }

    my $atr_bottom = $self->{price_height} + $self->{atr_height};

    my $line_x   = $x;
    my $snap_idx;
    if (defined $self->{start_idx} && defined $self->{end_idx}) {
        my $raw = $self->{price_scale}->x_to_index($x);
        if ($raw >= $self->{start_idx} && $raw <= $self->{end_idx}) {
            $snap_idx = $raw;
            $line_x   = $self->{price_scale}->index_to_center_x($raw);
        }
    }
    $self->{crosshair_idx} = $snap_idx;   # fuente unica de verdad para el HUD

    $self->{price_panel}->draw_crosshair($canvas, $line_x, $y, 0, $self->{price_height});
    $self->{atr_panel}->draw_crosshair($canvas, $line_x, $y, $self->{price_height}, $atr_bottom);
    $self->_draw_crosshair_time_label($snap_idx, $line_x);
}

# _draw_crosshair_time_label($idx, $cx)
# Dibuja la etiqueta de fecha/hora de la vela $idx centrada en $cx, sobre el eje
# de tiempo del fondo. Si $idx no esta definido (whitespace / fuera de datos),
# oculta la etiqueta. Usa el mismo indice que el snap del crosshair y el HUD.
sub _draw_crosshair_time_label {
    my ($self, $idx, $cx) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas && defined $cx;

    my $baseline = $self->_time_axis_y;
    my $ts = defined $idx ? $self->{market_data}->get_timestamp($idx) : undef;
    unless (defined $ts) {
        $self->{price_panel}->draw_time_label($canvas, $cx, undef, $baseline);
        return;
    }

    my $text = $self->_format_crosshair_time($ts);
    $self->{price_panel}->draw_time_label($canvas, $cx, $text, $baseline);
}

# _format_crosshair_time($epoch) -> $string
# Da formato legible al timestamp. Las temporalidades soportadas (1m/5m/15m)
# son intradia, por lo que se muestra fecha y hora: DD/MM/YYYY HH:MM.
# Si la vela cae exactamente a medianoche (00:00), se muestra solo la fecha
# (DD/MM/YYYY), "segun corresponda".
# _tz_offset() -> $seconds
# Offset de la zona del mercado (del dataset). Se usa con gmtime($ts + offset)
# para obtener la hora local del mercado SIN depender de la zona de la maquina.
sub _tz_offset {
    my ($self) = @_;
    return 0 unless $self->{market_data} && $self->{market_data}->can('get_tz_offset');
    return $self->{market_data}->get_tz_offset;
}

sub _format_crosshair_time {
    my ($self, $ts) = @_;
    return '' unless defined $ts;

    # gmtime(epoch + offset_mercado) = hora de reloj del mercado, independiente
    # de la zona horaria de la maquina local.
    my $local_ts = $ts + $self->_tz_offset;
    my ($min, $hour, $mday, $mon, $year) = (gmtime($local_ts))[1, 2, 3, 4, 5];
    my $date = sprintf('%02d/%02d/%04d', $mday, $mon + 1, $year + 1900);

    return $date if $hour == 0 && $min == 0;
    return sprintf('%s %02d:%02d', $date, $hour, $min);
}

sub _draw_hud {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;

    $canvas->delete('hud');
    my $tf        = $self->{active_tf} || '1m';
    my $scale_lbl = $self->{auto_scale} ? 'AUTO' : 'MANUAL';
    my $visible   = $self->{current_visible_bars} || $self->{initial_visible_bars} || 0;

    # OHLC de la vela bajo el cursor. Usa el MISMO indice que el snap del
    # crosshair y la fecha (crosshair_idx), garantizando que fecha, OHLC y la
    # linea vertical correspondan exactamente a la misma vela.
    my $ohlc_line = '';
    my $idx = $self->{crosshair_idx};
    if (defined $idx) {
        my $candle = $self->{market_data}->get_candle($idx);
        if ($candle) {
            $ohlc_line = sprintf('O:%.2f H:%.2f L:%.2f C:%.2f',
                $candle->{open}, $candle->{high},
                $candle->{low},  $candle->{close});
        }
    }

    my $hud_h = $ohlc_line ? 90 : 72;
    my $replay_line = '';
    if ($self->{replay_controller} && $self->{replay_controller}->is_active()) {
        my $rc = $self->{replay_controller};
        my $pos = ($rc->{current_index} // 0) + 1;
        my $tot = $self->{market_data} ? $self->{market_data}->size() : 0;
        my $st  = $rc->{playing} ? 'PLAY' : 'PAUSE';
        my $spd = $rc->{speed} || 1;
        $replay_line = sprintf('REPLAY %s %sx  %d/%d', $st, $spd, $pos, $tot);
        $hud_h += 16;
    }

    $canvas->createRectangle(4, 4, 340, $hud_h,
        -fill => '#0d1117', -outline => '#2a2e39', -width => 1, -tags => ['hud']);
    $canvas->createText(12, 16,
        -text => $tf, -fill => '#e0e3ea',
        -anchor => 'w', -font => 'Helvetica 11 bold', -tags => ['hud']);
    my $sc = $self->{auto_scale} ? '#4dd0e1' : '#ff9800';
    $canvas->createText(60, 16,
        -text => "Escala: $scale_lbl", -fill => $sc,
        -anchor => 'w', -font => 'Helvetica 8', -tags => ['hud']);
    $canvas->createText(12, 33,
        -text => "Velas: $visible", -fill => '#787b86',
        -anchor => 'w', -font => 'Helvetica 8', -tags => ['hud']);
    $canvas->createText(12, 48,
        -text => '1-8: TF   r: Reset   a: Escala   p: Replay   Space: Play/Pause   [ ]: Step',
        -fill => '#4a4f5e', -anchor => 'w', -font => 'Helvetica 7', -tags => ['hud']);
    $canvas->createText(12, 61,
        -text => 'Rueda: Zoom H   Ctrl+Rueda: Zoom cursor   Shift+]: FF   Esc: Salir replay',
        -fill => '#4a4f5e', -anchor => 'w', -font => 'Helvetica 7', -tags => ['hud']);

    my $y_extra = 0;
    if ($replay_line) {
        $canvas->createText(12, 74,
            -text => $replay_line, -fill => '#66bb6a',
            -anchor => 'w', -font => 'Helvetica 8 bold', -tags => ['hud']);
        $y_extra = 16;
    }

    if ($ohlc_line) {
        $canvas->createText(12, 74 + $y_extra,
            -text   => $ohlc_line,
            -fill   => '#c0c4cc',
            -anchor => 'w',
            -font   => 'Helvetica 7',
            -tags   => ['hud']);
    }
}

# ── Eje de tiempo ─────────────────────────────────────────────────────────────

sub compute_intraday_labels {
    my ($self, $start, $end) = @_;
    return [] unless $self->{market_data};
    return [] unless defined $start && defined $end && $end >= $start;

    my $start_idx = $start;
    my $count     = $end - $start + 1;
    my $cw        = $self->{candle_width} || 4;
    my $step      = int(80 / $cw);
    $step = 1 if $step < 1;
    # Con muchas velas visibles, espaciar el escaneo de timestamps (solo etiquetas).
    if ($count > 2000) {
        my $scan = int($count / 400) + 1;
        $step = $step > $scan ? $step : $scan;
    }

    my %pos;
    for (my $i = 0; $i < $count; $i += $step) { $pos{$i} = 1; }

    my $tz      = $self->_tz_offset;
    my $prev_dk;
    my $day_step = $step;
    if ($count > 2000) {
        $day_step = int($count / 800) + 1;
        $day_step = $step if $day_step < $step;
    }
    for (my $i = 0; $i < $count; $i += $day_step) {
        my $ts = $self->{market_data}->get_timestamp($start_idx + $i);
        next unless defined $ts;
        my ($mday, $mon) = (gmtime($ts + $tz))[3, 4];
        my $dk = $mday * 100 + $mon;
        if (!defined $prev_dk || $dk != $prev_dk) {
            $pos{$i} = 1;
        }
        $prev_dk = $dk;
    }

    my $total     = $self->{total_bars} || 0;
    my $last_hist = $total > 0 ? $total - 1 : undef;
    if (defined $last_hist && $last_hist >= $start_idx && $last_hist <= $end) {
        $pos{ $last_hist - $start_idx } = 1;
    }

    my @labels;
    $prev_dk = undef;
    for my $i (sort { $a <=> $b } keys %pos) {
        my $ts = $self->{market_data}->get_timestamp($start_idx + $i);
        next unless defined $ts;
        my ($min, $hour, $mday, $mon) = (gmtime($ts + $tz))[1, 2, 3, 4];
        my $dk   = $mday * 100 + $mon;
        my $text = (!defined $prev_dk || $dk != $prev_dk)
            ? sprintf('%02d/%02d', $mday, $mon + 1)
            : sprintf('%02d:%02d', $hour, $min);
        $prev_dk = $dk;
        push @labels, { index => $start_idx + $i, text => $text };
    }
    return \@labels;
}

# ── Estabilidad visual ────────────────────────────────────────────────────────

# _keep_candles_visible()
# Intencionalmente inactivo: en MANUAL la escala Y queda fija hasta que el usuario
# la modifique en la franja del eje Y (o vuelva a AUTO con la tecla A).

1;

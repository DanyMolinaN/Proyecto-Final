package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::Render
# =============================================================================
# Pipeline de render: request_render, render, overlays y paneles.
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

sub request_render {
    my ($self) = @_;
    return unless $self->{canvas};
    return if $self->{pending};
    $self->{pending} = 1;
    $self->{canvas}->afterIdle(sub {
        $self->{pending} = 0;
        $self->render();
    });
}

# _request_render_throttled()
# Igual que request_render pero con tope de ~60fps (coalescing temporal). Para
# gestos continuos (pan con arrastre, drag de la escala Y, zoom con rueda) que de
# otro modo dispararian un render() SINCRONO por cada pixel/notch de movimiento,
# saturando el event loop monohilo de Tk. El estado del viewport ya se actualizo
# antes de llamar a esto, asi que el render coalescido usa siempre el ultimo.
sub _request_render_throttled {
    my ($self) = @_;
    return unless $self->{canvas};
    return if $self->{pending};
    $self->{pending} = 1;
    $self->{canvas}->after(16, sub {
        $self->{pending} = 0;
        $self->render();
    });
}

sub render {
    my ($self) = @_;
    return unless $self->{canvas} && $self->{market_data};

    my ($start, $end) = $self->compute_window();
    return if $end < $start;
    my $total = $self->{total_bars} || $self->{market_data}->size;
    if ($self->{replay_controller} && $self->{replay_controller}->can('visible_limit') && $self->{replay_controller}->{enabled}) {
        my $limit = $self->{replay_controller}->visible_limit($total);
        $end = $limit if defined $limit && $end > $limit;
        $end = $start if $end < $start;
    }

    # Relleno de 1 vela a cada lado: con el desplazamiento sub-pixel (x_shift) la
    # vela del borde podria dejar un hueco de hasta media vela. Dibujar una vela
    # extra a cada lado cubre ese hueco (las sobrantes caen fuera del area util).
    my $draw_start = $start - 1; $draw_start = 0          if $draw_start < 0;
    my $draw_end   = $end   + 1; $draw_end   = $total - 1 if $draw_end > $total - 1;
    if ($self->{replay_controller} && $self->{replay_controller}->{enabled}) {
        my $limit = $self->{replay_controller}->visible_limit($total);
        $draw_end = $limit if defined $limit && $draw_end > $limit;
    }

    my ($data_slice, $slice_first, $draw_stride) =
        $self->_prepare_draw_slice($draw_start, $draw_end);
    return unless $data_slice && ref $data_slice eq 'ARRAY' && @$data_slice;

    # Auto-escala Y (cuando auto_scale esta activo): se calcula sobre una ventana
    # ESTABLE de las ultimas `eff` velas (las que caben en el viewport segun el
    # zoom), terminando en la ultima vela real visible. NO se usa solo el tramo
    # real visible: al desplazarse hacia el futuro (whitespace) quedarian pocas
    # velas y el rango colapsaria, agrandando las velas de forma exagerada.
    #   - Scroll normal / historico: la ventana coincide con las velas visibles
    #     => el rango se ajusta exactamente a lo que se ve (como TradingView).
    #   - Scroll hacia el futuro (whitespace): la ventana se mantiene en las
    #     ultimas `eff` velas => la escala queda estable y las velas no crecen.
    if ($self->{auto_scale} && !$self->{_skip_auto_scale} && !$self->{_auto_y_frozen}) {
        my $eff = $self->{current_visible_bars} || $self->{initial_visible_bars};
        $eff = $total      if defined $total && $eff > $total;
        my $s_end   = $end;
        my $s_start = $s_end - $eff + 1;
        $s_start = 0 if $s_start < 0;

        my ($min_p, $max_p) = $self->_auto_scale_y_range($s_start, $s_end);
        if (defined $min_p && defined $max_p && $max_p > $min_p) {
            # Padding en pixeles: deja margen para etiquetas SMC + volumen.
            my ($lo, $hi) = $self->_auto_scale_fit_range($min_p, $max_p);
            $self->{price_scale}->set_range($lo, $hi) if defined $lo && defined $hi;
        }
    }

    # start_index LOGICO (no el de relleno) + x_shift sub-pixel comun a las dos
    # escalas, para que velas, ATR, eje de tiempo y crosshair queden alineados.
    my $xshift = $self->{x_shift} || 0;
    # start_index = view_start (indice logico del borde izquierdo, puede ser
    # negativo si hay whitespace a la izquierda). Asi las velas se anclan al borde
    # derecho cuando se comprime toda la data, sin pegarse a la izquierda.
    my $vstart = defined $self->{view_start} ? $self->{view_start} : $start;
    my $max_draw = $self->_max_draw_bars();
    $self->{price_scale}->{start_index}  = $vstart;
    $self->{atr_scale}->{start_index}    = $vstart;
    $self->{price_scale}->{x_shift}      = $xshift;
    $self->{atr_scale}->{x_shift}        = $xshift;
    $self->{price_scale}->{max_draw_bars} = $max_draw;
    $self->{price_scale}->{draw_stride}    = $draw_stride;
    $self->{price_scale}->{draw_end_index} = $draw_end;
    $self->{atr_scale}->{max_draw_bars}     = $max_draw;
    $self->{atr_scale}->{draw_stride}       = $draw_stride;
    $self->{atr_scale}->{draw_end_index}    = $draw_end;

    my $tick_labels = $self->compute_intraday_labels($start, $end);

    $self->_update_y_data_cache($start, $end);
    # FIX-1: en MANUAL no reencajar la escala en cada frame (anula pan/zoom).
    # Solo recuperar si los datos visibles quedaron totalmente fuera del rango.
    $self->_repair_manual_scale_if_data_outside('price');

    $self->{price_panel}->render($self->{canvas}, $data_slice, $self->{price_scale}, $slice_first);
    $self->{price_scale}->_draw_y_scale($self->{canvas});
    # Caja/linea del ultimo precio por ENCIMA de la mascara del eje Y.
    $self->{canvas}->raise('visible_background');
    $self->{canvas}->raise('visible_price');

    # Overlays SOLO en el panel de precios (antes del ATR, estilo TradingView).
    $self->_prepare_overlay_data();
    $self->_draw_overlays();
    $self->_clip_overlays_to_price_panel();

    # Fondos y separadores de paneles (tapa cualquier desborde residual).
    $self->_draw_pane_layout();

    my $atr_ind = $self->{indicator_manager}
        ? $self->{indicator_manager}->get('atr')
        : undef;

    if ($atr_ind) {
        my $values = $atr_ind->get_values || [];
        if (@$values) {
            my $period = $atr_ind->{period} || 14;
            my $aoff   = $period - 1;
            # Mismo rango de relleno que las velas (draw_start..draw_end).
            my $vs = $draw_start - $aoff;  $vs = 0         if $vs < 0;
            my $ve = $draw_end   - $aoff;  $ve = $#$values if $ve > $#$values;
            if ($vs <= $ve) {
                my @vatr;
                my $atr_stride = 1;
                my $atr_n = $ve - $vs + 1;
                if ($atr_n > $max_draw) {
                    $atr_stride = int($atr_n / $max_draw) + 1;
                    for (my $j = $vs; $j <= $ve; $j += $atr_stride) {
                        push @vatr, $values->[$j];
                    }
                    push @vatr, $values->[$ve]
                        if $ve >= $vs && (!@vatr || $vatr[-1] != $values->[$ve]);
                }
                else {
                    @vatr = @{$values}[$vs .. $ve];
                }
                my $atr_first = $vs + $aoff;
                $self->_update_y_data_cache($start, $end, \@vatr);
                if ($self->{atr_auto_scale} && $self->{_cached_atr_y}
                    && @{$self->{_cached_atr_y}} == 2)
                {
                    Market::Core::ATRPanelZoom::fit_to_data(
                        $self->{atr_scale}, @{$self->{_cached_atr_y}},
                    );
                }
                elsif (!$self->{atr_auto_scale}) {
                    $self->_repair_manual_scale_if_data_outside('atr');
                }
                $self->{atr_scale}->{draw_stride} = $atr_stride;
                $self->{atr_panel}->render($self->{canvas}, \@vatr, $self->{atr_scale}, $atr_first);
                $self->{atr_scale}->_draw_y_scale($self->{canvas});
                $self->{canvas}->raise('atr_line');
                $self->{canvas}->raise('atr_y_scale');
                $self->{canvas}->raise('atr_background');
                $self->{canvas}->raise('atr_last_value');
                $self->{canvas}->raise('panel_separator');
            }
        }
    }

    # Eje de tiempo al fondo (debajo del panel ATR).
    $self->{price_panel}->draw_time_axis(
        $self->{canvas}, $tick_labels, $self->{price_scale},
        $self->_time_axis_y, $self->{time_axis_height});
    $self->{canvas}->raise('time_labels');

    $self->_draw_replay_marker();
    # Durante zoom: solo crosshair (alineado al nuevo mapeo X); HUD diferido.
    $self->_draw_crosshair_all();
    $self->_draw_hud() unless $self->{_zoom_frame};
}

sub _draw_overlays {
    my ($self) = @_;
    return unless $self->{canvas};
    return unless $self->{overlay_manager};

    # Limpiar capas desactivadas. Las capas activas gestionan su propio diff:
    # algunas reutilizan objetos persistentes entre renders para evitar churn.
    if ($self->{overlay_manager}->can('list')) {
        for my $name (@{ $self->{overlay_manager}->list() || [] }) {
            next if $self->{overlay_manager}->is_enabled($name);
            my $overlay = $self->{overlay_manager}->get($name);
            $overlay->clear($self->{canvas}) if $overlay && $overlay->can('clear');
        }
    }

    my $overlays = $self->{overlay_manager}->can('active_overlays')
        ? $self->{overlay_manager}->active_overlays()
        : [];
    return unless $overlays && ref($overlays) eq 'ARRAY';

    for my $overlay (@$overlays) {
        next unless $overlay;
        next unless $overlay->can('draw');
        eval {
            $overlay->draw(
                canvas      => $self->{canvas},
                scale       => $self->{price_scale},
                atr_scale   => $self->{atr_scale},
                market_data => $self->{market_data},
                start_idx   => $self->{start_idx},
                end_idx     => $self->{end_idx},
                view_start  => $self->{view_start},
                x_shift     => $self->{x_shift},
                clip_y_top    => 0,
                clip_y_bottom => $self->{price_height},
                data        => $overlay->{data},
            );
        };
        if ($@) {
            my $name = ref($overlay) || 'UnknownOverlay';
            warn "Error drawing overlay $name: $@\n";
        }
    }

    # Asegurar que overlays queden encima de velas/fondos del panel de precios.
    for my $tag (qw(overlay_liquidity overlay_fvg overlay_structure)) {
        eval { $self->{canvas}->raise($tag); };
        if ($@) {
            warn "Error raising layer $tag: $@\n";
        }
    }

    return $self;
}

# _draw_pane_layout()
# Separa visualmente precio | ATR | eje de tiempo (estilo TradingView).
sub _draw_pane_layout {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;

    my $w   = $self->{width}  || 1000;
    my $ph  = $self->{price_height} || 0;
    my $ah  = $self->{atr_height}   || 140;
    my $tah = $self->{time_axis_height} || 42;
    my $ty  = $ph + $ah;

    $canvas->delete('pane_layout');

    # Fondo del panel ATR (cubre desbordes de overlays/velas).
    $canvas->createRectangle(
        0, $ph, $w, $ty,
        -fill => '#0f1720', -outline => '',
        -tags => ['pane_layout', 'atr_pane_bg'],
    );

    # Fondo del eje de tiempo.
    $canvas->createRectangle(
        0, $ty, $w, $ty + $tah,
        -fill => '#131722', -outline => '',
        -tags => ['pane_layout', 'time_axis_bg'],
    );

    # Separador precio / ATR.
    $canvas->createLine(
        0, $ph, $w, $ph,
        -fill => '#363a45', -width => 2,
        -tags => ['pane_layout', 'panel_separator'],
    );

    return $self;
}

# _clip_overlays_to_price_panel()
# Oculta elementos de overlay que queden por debajo del panel de precios.
sub _clip_overlays_to_price_panel {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    my $ph     = $self->{price_height} || 0;
    return unless $canvas && $ph > 0;

    my @tags = qw(overlay_liquidity overlay_fvg overlay_structure);

    for my $tag (@tags) {
        for my $id ($canvas->find('withtag', $tag)) {
            my @bbox = $canvas->bbox($id);
            next unless @bbox >= 4;
            if ($bbox[1] >= $ph - 1) {
                $canvas->itemconfigure($id, -state => 'hidden');
            }
        }
    }
    return $self;
}

# _in_atr_panel($y) -> bool
sub _in_atr_panel {
    my ($self, $y) = @_;
    return 0 unless defined $y;
    my $ph = $self->{price_height} || 0;
    my $ah = $self->{atr_height}   || 0;
    return ($y >= $ph && $y <= $ph + $ah) ? 1 : 0;
}

# _draw_replay_marker()
# Linea vertical en la vela del puntero de replay (referencia visual).
sub _draw_replay_marker {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    $canvas->delete('replay_marker');

    my $rc = $self->{replay_controller};
    return unless $rc && $rc->is_active();

    my $idx = $rc->{current_index};
    return unless defined $idx;

    my $x = $self->{price_scale}->index_to_center_x($idx);
    my $y0 = 0;
    my $y1 = ($self->{price_height} || 0) + ($self->{atr_height} || 0);

    $canvas->createLine($x, $y0, $x, $y1,
        -fill => '#66bb6a', -width => 1, -dash => [6, 4],
        -tags => ['replay_marker'],
    );
    $canvas->raise('replay_marker');
    return $self;
}

# _time_axis_y() -> $y
# Coordenada Y donde vive el eje de tiempo comun: justo debajo del panel ATR,
# al fondo del grafico. Las etiquetas del eje y la fecha del crosshair se anclan
# a esta linea, garantizando sincronia entre todos los paneles.
sub _time_axis_y {
    my ($self) = @_;
    return $self->{price_height} + $self->{atr_height};
}

# Registra solo overlays de la primera entrega (29/06): Liquidez, SMC, FVG.
sub _register_overlays {
    my ($self) = @_;
    return unless $self->{overlay_manager} && $self->{overlay_manager}->can('register');

    my @overlays = (
        [liquidity       => $self->{liquidity_overlay}],
        [fvg             => $self->{fvg_overlay}],
        [structure       => $self->{structure_overlay}],
        [orderblock      => $self->{orderblock_overlay}],
        [volume_profile  => $self->{volume_profile_overlay}],
        [anchored_vwap   => $self->{anchored_vwap_overlay}],
        [fibonacci       => $self->{fibonacci_overlay}],
        [supply_demand   => $self->{supply_demand_overlay}],
        [trend_channel       => $self->{trend_channel_overlay}],
        
        # Phase 2
        [trailing_extremes => $self->{trailing_extremes_overlay}],
        [premium_discount  => $self->{premium_discount_overlay}],
        [mtf_levels        => $self->{mtf_levels_overlay}],
        [zzmtf_overlay     => $self->{zzmtf_overlay}],
    );

    for my $entry (@overlays) {
        my ($name, $overlay) = @$entry;
        next unless $overlay;
        $self->{overlay_manager}->register($name, $overlay);
        $self->{overlay_manager}->enable($name) if $self->{overlay_manager}->can('enable');
    }
    $self->_sync_overlay_layer_state();
    return $self;
}

# ── Cache de analisis (desacople ANALISIS / RENDER) ───────────────────────────
#
# Los motores de Liquidity, Structure y FVG analizan el dataset completo;
# su resultado solo cambia cuando cambian los DATOS (ver entregable 29/06).

# invalidate_analysis_cache()
# Limpia la cache y resetea todos los engines via EngineRegistry.

1;

package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::Replay
# =============================================================================
# Logica de replay (play/pause, seek, tick, marcadores de UI).
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

sub _cancel_replay_timer {
    my ($self) = @_;
    if ($self->{_replay_after} && $self->{canvas}) {
        eval { $self->{canvas}->afterCancel($self->{_replay_after}); };
        $self->{_replay_after} = undef;
    }
    return $self;
}

sub _replay_sync_viewport {
    my ($self) = @_;
    my $rc = $self->{replay_controller};
    return unless $rc && $rc->is_active() && $self->{market_data};
    # El offset se maneja en el espacio "eff_total" que usa compute_window
    # (eff_total = puntero_replay + 1), donde offset=0 == "el puntero de
    # replay es la ultima vela visible" (igual que offset=0 fuera de replay
    # significa "la ultima vela real es la ultima visible"). Antes se
    # calculaba con el total REAL de velas, lo que desalineaba el anclaje
    # respecto al puntero durante la reproduccion.
    $self->{offset} = 0;
    return $self;
}

sub _replay_warn {
    my ($self, $action, $err) = @_;
    return unless defined $err && $err ne '';
    chomp $err;
    warn "[Replay][$action] $err\n";
}

sub _replay_debug_log {
    my ($self, $action) = @_;
    my $rc = $self->{replay_controller};
    my $current = ($rc && defined $rc->{current_index}) ? $rc->{current_index} : 'undef';
    my $playing = ($rc && $rc->{playing}) ? 1 : 0;
    my $enabled = ($rc && $rc->{enabled}) ? 1 : 0;
    warn "[Replay][$action] current_index=$current playing=$playing enabled=$enabled\n";
}

sub _replay_safe_sync_controls {
    my ($self, $action) = @_;
    local $@;
    my $ok = eval {
        $self->_replay_sync_controls();
        $self->_replay_sync_speed_buttons();
        1;
    };
    $self->_replay_warn("$action/sync_controls", $@) unless $ok;
    return $self;
}

sub _replay_run_handler {
    my ($self, $action, $code) = @_;
    local $@;
    my $ok = eval {
        $code->();
        1;
    };
    $self->_replay_warn($action, $@) unless $ok;
    $self->_replay_safe_sync_controls($action);
    $self->_replay_debug_log($action);
    return $self;
}

# _replay_raw_total() -> N velas reales (ignora frontera de replay)
sub _replay_raw_total {
    my ($self) = @_;
    my $md = $self->{market_data} or return 0;
    if ($md->can('raw_last_index')) {
        my $idx = $md->raw_last_index();
        return (defined $idx && $idx >= 0) ? ($idx + 1) : 0;
    }
    return $md->size() || 0;
}

# Alinea MarketData::set_replay_boundary con el puntero del ReplayController
# (mismo modelo que Proyecto_David) para que size()/last_candle() no filtren
# el futuro y los indicadores David avancen bien.
sub _replay_sync_market_boundary {
    my ($self) = @_;
    my $md = $self->{market_data} or return;
    my $rc = $self->{replay_controller};

    if ($rc && $rc->is_active()) {
        my $idx = $rc->{current_index} // 0;
        my $c = $md->can('raw_get_candle')
            ? $md->raw_get_candle($idx)
            : undef;
        if (!$c && $md->can('get_candle')) {
            # Sin frontera aun: get_candle ve todo
            $c = $md->get_candle($idx);
        }
        my $ts = $c ? ($c->{timestamp} // $c->{ts}) : undef;
        if (defined $ts && $md->can('set_replay_boundary')) {
            $md->set_replay_boundary($ts);
        }
    }
    elsif ($md->can('clear_replay_boundary')) {
        $md->clear_replay_boundary();
    }
    return $self;
}

# _refresh_structure_zigzag()
# Recalcula engines visibles (SMC/FVG/OB/TLC/...) y avanza David Tools activos.
sub _refresh_structure_zigzag {
    my ($self) = @_;
    return unless $self->{market_data};

    $self->_replay_sync_market_boundary();

    my $s = $self->{overlay_settings};
    my $on = sub {
        my ($k) = @_;
        return (!$s || !$s->can('enabled')) ? 1 : ($s->enabled($k) ? 1 : 0);
    };

    my $need_core =
           !$s
        || $on->('show_swing_high') || $on->('show_swing_low')
        || $on->('show_hh') || $on->('show_hl') || $on->('show_lh') || $on->('show_ll')
        || $on->('show_bos_external') || $on->('show_bos_internal')
        || $on->('show_choch_external') || $on->('show_choch_internal')
        || $on->('show_internal_zigzag') || $on->('show_external_zigzag')
        || $on->('show_internal_swings') || $on->('show_external_swings')
        || $on->('show_eqh') || $on->('show_eql')
        || $on->('show_fvg')
        || $on->('show_ob_external') || $on->('show_ob_internal') || $on->('show_orderblocks')
        || $on->('show_trend_channel')
        || $on->('show_liquidity_levels') || $on->('show_fibonacci')
        || $on->('show_zzmtf_internal') || $on->('show_zzmtf_external');

    my @only;
    if ($need_core) {
        push @only, 'smc_structure';
        push @only, 'fvg'           if !$s || $on->('show_fvg');
        push @only, 'orderblock'    if !$s || $on->('show_ob_external') || $on->('show_ob_internal')
            || $on->('show_orderblocks') || $on->('show_trend_channel');
        push @only, 'trend_channel' if !$s || $on->('show_trend_channel');
        push @only, 'liquidity'     if $on->('show_eqh') || $on->('show_eql')
            || $on->('show_liquidity_levels') || $on->('show_sweeps')
            || $on->('show_grabs') || $on->('show_runs');
        push @only, 'fibonacci'     if $on->('show_fibonacci');
        push @only, 'zzmtf_overlay' if $on->('show_zzmtf_internal') || $on->('show_zzmtf_external');
    }

    if (@only && $self->can('rebuild_analysis_cache')) {
        $self->rebuild_analysis_cache(
            only       => \@only,
            keep_cache => 1,
        );
    }

    $self->_refresh_david_indicators_for_replay();

    return $self->{analysis_cache} ? $self->{analysis_cache}{smc_structure} : undef;
}

# Avanza indicadores David: update_last si el puntero avanzo 1 vela;
# rebuild_one si seek/atras/entrada (como David rebuild_range).
# Nunca usa velas > frontera de replay (MarketData::size ya recortado).
sub _refresh_david_indicators_for_replay {
    my ($self) = @_;
    my $im = $self->{indicator_manager} or return;
    my $om = $self->{overlay_manager} or return;
    my $md = $self->{market_data} or return;
    my $rc = $self->{replay_controller};

    my @keys = qw(zigzag_vp2_david zigzag_mtf2_david fibonacci_david liquidity_david);
    my @active = grep {
        $om->can('is_enabled') && $om->is_enabled($_)
    } @keys;
    return unless @active;

    my $cur  = ($rc && $rc->is_active()) ? ($rc->{current_index} // 0) : undef;
    my $prev = $self->{_david_replay_built_to};
    my $size = $md->size // 0;

    my $forward_one = defined $cur && defined $prev && $cur == $prev + 1;

    # Si el buffer interno supera el size visible, hay datos del futuro → rebuild
    my $has_future = 0;
    for my $key (@active) {
        my $ind = $im->get($key) or next;
        my $buf = $ind->{_c} || [];
        if (@$buf > $size) {
            $has_future = 1;
            last;
        }
    }

    if ($forward_one && !$has_future) {
        for my $key (@active) {
            my $ind = $im->get($key);
            next unless $ind && $ind->can('update_last');
            # Defensa: no avanzar si ya estamos al tamaño del market recortado
            my $buf = $ind->{_c} || [];
            next if @$buf >= $size;
            $ind->update_last($md);
        }
    }
    else {
        for my $key (@active) {
            $im->rebuild_one($key, $md) if $im->can('rebuild_one');
        }
    }

    $self->{_david_replay_built_to} = $cur;
    return $self;
}

sub _replay_apply {
    my ($self) = @_;
    $self->_replay_sync_viewport();
    $self->_refresh_structure_zigzag();
    local $@;
    my $ok = eval {
        $self->render();
        1;
    };
    $self->_replay_warn('apply', $@) unless $ok;
    $self->_replay_safe_sync_controls('apply');
    return $self;
}

sub _replay_index_from_canvas_x {
    my ($self, $x, $y) = @_;
    return undef unless $self->{market_data} && $self->{price_scale};
    return undef if $self->_in_price_y_axis_strip($x, $y);
    return undef if $self->_in_atr_y_axis_strip($x, $y);

    my $idx = $self->{price_scale}->x_to_index($x);
    return undef unless defined $idx;
    my $total = $self->{market_data}->size();
    return undef unless $total > 0;
    $idx = 0 if $idx < 0;
    $idx = $total - 1 if $idx >= $total;
    return $idx;
}

sub _replay_sync_speed_buttons {
    my ($self) = @_;
    my $buttons = $self->{_replay_speed_buttons};
    return $self unless $buttons && ref($buttons) eq 'HASH';

    my $rc = $self->{replay_controller};
    my $current = $rc ? ($rc->{speed} || 1) : ($self->{_replay_speed_var} || 1);
    for my $speed (keys %$buttons) {
        my $btn = $buttons->{$speed};
        next unless $btn;
        my $active = abs(($speed + 0) - ($current + 0)) < 0.0001;
        eval {
            $btn->configure(
                -background => $active ? '#4d5f2b' : '#2a2e39',
                -relief     => $active ? 'sunken' : 'raised',
            );
        };
    }
    return $self;
}

sub _replay_start_at_index {
    my ($self, $idx, $autoplay) = @_;
    return unless $self->{market_data} && $self->{replay_controller};
    my $total = $self->_replay_raw_total();
    return unless $total > 0;
    $idx = 0 unless defined $idx;
    $idx = 0 if $idx < 0;
    $idx = $total - 1 if $idx >= $total;

    $self->_cancel_replay_timer();
    $self->{_david_replay_built_to} = undef;  # fuerza rebuild al entrar
    $self->{replay_controller}->enter_replay($idx, $total);
    $self->{_replay_select_mode} = 0;
    if ($autoplay && $idx < $total - 1) {
        $self->{replay_controller}->play();
        $self->_replay_schedule_tick();
    }
    $self->_replay_apply();
    return $self;
}

sub _replay_select_start {
    my ($self) = @_;
    return $self->_replay_run_handler('select_start', sub {
        $self->{_replay_select_mode} = 1;
        $self->_cancel_replay_timer();
        my $canvas = $self->{canvas};
        eval { $canvas->configure(-cursor => 'crosshair') } if $canvas;
    });
}

sub _replay_pick_from_canvas {
    my ($self, $x, $y) = @_;
    return $self->_replay_run_handler('pick_start', sub {
        my $canvas = $self->{canvas};
        eval { $canvas->configure(-cursor => '') } if $canvas;
        my $idx = $self->_replay_index_from_canvas_x($x, $y);
        return unless defined $idx;
        $self->_replay_start_at_index($idx, 0);
    });
}

sub _replay_enter {
    my ($self) = @_;
    return $self->_replay_run_handler('enter', sub {
        return unless $self->{market_data} && $self->{replay_controller};
        my $total = $self->_replay_raw_total();
        return unless $total > 0;

        my $idx = $self->{crosshair_idx};
        if (!defined $idx) {
            my ($start, $end) = $self->compute_window();
            $idx = $end;
        }
        $idx = $total - 1 if $idx >= $total;

        $self->_replay_start_at_index($idx, 0);
    });
}

sub _replay_exit {
    my ($self) = @_;
    return $self->_replay_run_handler('exit', sub {
        return unless $self->{replay_controller};
        $self->{_replay_select_mode} = 0;
        eval { $self->{canvas}->configure(-cursor => '') } if $self->{canvas};
        $self->_cancel_replay_timer();
        $self->{replay_controller}->exit_replay();
        $self->{_david_replay_built_to} = undef;
        if ($self->{market_data} && $self->{market_data}->can('clear_replay_boundary')) {
            $self->{market_data}->clear_replay_boundary();
        }
        # Salida: reconstruir analisis completo de overlays activos + David
        $self->invalidate_analysis_cache() if $self->can('invalidate_analysis_cache');
        $self->rebuild_analysis_cache() if $self->can('rebuild_analysis_cache');
        $self->_recompute_active_david_indicators() if $self->can('_recompute_active_david_indicators');
        $self->render();
    });
}

sub _replay_toggle_play {
    my ($self) = @_;
    return $self->_replay_run_handler('toggle_play', sub {
        my $rc = $self->{replay_controller};
        return unless $rc && $rc->is_active();

        if ($rc->{playing}) {
            $rc->pause();
            $self->_cancel_replay_timer();
            $self->render();
            return;
        }

        my $total = $self->_replay_raw_total();
        return unless $total > 0;
        return if $rc->{current_index} >= $total - 1;

        $rc->play();
        $self->_replay_apply();
        $self->_replay_schedule_tick();
    });
}

# _replay_set_speed($speed)
# Cambia el multiplicador de reproduccion (0.25x .. 10x, estilo TradingView).
# El siguiente tick programado en _replay_schedule_tick ya lee {speed} en vivo,
# asi que el cambio se aplica de inmediato sin reiniciar el timer.
sub _replay_set_speed {
    my ($self, $speed) = @_;
    return $self->_replay_run_handler('set_speed', sub {
        return unless $self->{replay_controller};
        $self->{_replay_speed_var} = $speed;
        $self->{replay_controller}->set_speed($speed);
        $self->_replay_sync_speed_buttons();
        $self->render();
    });
}

# _replay_seek_scale_changed($value)
# Callback del slider de recorrido: permite saltar directo a cualquier vela
# del historico (scrubbing), igual que la barra de Replay de TradingView.
# Al arrastrar, se pausa automaticamente (si estaba en play) para no pelear
# con el timer de auto-avance.
sub _replay_seek_scale_changed {
    my ($self, $val) = @_;
    return if $self->{_replay_scale_updating};
    return $self->_replay_run_handler('seek', sub {
        my $rc = $self->{replay_controller};
        return unless $rc && $rc->is_active() && $self->{market_data};
        my $total = $self->_replay_raw_total();
        return unless $total > 0;

        my $target = int($val + 0.5);
        $target = 0 if $target < 0;
        $target = $total - 1 if $target >= $total;
        return if defined $rc->{current_index} && $target == $rc->{current_index};

        $rc->pause();
        $self->_cancel_replay_timer();
        $self->{_david_replay_built_to} = undef;  # seek: rebuild
        $rc->seek($target, $total);
        $self->_replay_apply();
    });
}

# _replay_sync_controls()
# Refleja el estado actual del ReplayController en el slider de recorrido:
# rango habilitado/deshabilitado segun si el replay esta activo, y posicion
# actualizada en cada tick/step/seek. Usa un flag de guarda para no disparar
# _replay_seek_scale_changed de vuelta cuando el valor se fija programaticamente.
sub _replay_sync_controls {
    my ($self) = @_;
    my $scale = $self->{_replay_scale};
    return unless $scale;

    my $rc    = $self->{replay_controller};
    my $total = $self->_replay_raw_total();

    if ($rc && $rc->is_active() && $total > 0) {
        $scale->configure(-state => 'normal', -from => 0, -to => $total - 1);
        $self->{_replay_scale_updating} = 1;
        local $@;
        eval { $scale->set($rc->{current_index} // 0); };
        $self->{_replay_scale_updating} = 0;
    }
    else {
        my $to = $total > 0 ? $total - 1 : 1;
        $scale->configure(-state => 'disabled', -from => 0, -to => $to);
        $self->{_replay_scale_updating} = 1;
        local $@;
        eval { $scale->set(0); };
        $self->{_replay_scale_updating} = 0;
    }
    return $self;
}

sub _replay_step_forward {
    my ($self) = @_;
    return $self->_replay_run_handler('step_forward', sub {
        my $rc = $self->{replay_controller};
        return unless $rc && $rc->is_active();

        my $total = $self->_replay_raw_total();
        $rc->pause();
        $self->_cancel_replay_timer();
        $rc->step_forward($total);
        $self->_replay_apply();
    });
}

sub _replay_step_backward {
    my ($self) = @_;
    return $self->_replay_run_handler('step_backward', sub {
        my $rc = $self->{replay_controller};
        return unless $rc && $rc->is_active();

        $rc->pause();
        $self->_cancel_replay_timer();
        $self->{_david_replay_built_to} = undef;  # atras: rebuild
        $rc->step_backward();
        $self->_replay_apply();
    });
}

sub _replay_fast_forward {
    my ($self) = @_;
    return $self->_replay_run_handler('fast_forward', sub {
        my $rc = $self->{replay_controller};
        return unless $rc && $rc->is_active();

        my $total = $self->_replay_raw_total();
        $rc->pause();
        $self->_cancel_replay_timer();
        # Salto >1: no update_last secuencial — rebuild
        $self->{_david_replay_built_to} = undef;
        $rc->fast_forward(10, $total);
        $self->_replay_apply();
    });
}

sub _replay_schedule_tick {
    my ($self) = @_;
    my $rc = $self->{replay_controller};
    return unless $rc && $rc->{playing} && $self->{canvas};
    $self->_cancel_replay_timer();

    my $total = $self->_replay_raw_total();
    if ($total <= 0 || $rc->{current_index} >= $total - 1) {
        $rc->stop();
        local $@;
        my $ok = eval {
            $self->render();
            1;
        };
        $self->_replay_warn('schedule_tick/render_stop', $@) unless $ok;
        $self->_replay_safe_sync_controls('schedule_tick/render_stop');
        $self->_replay_debug_log('schedule_tick/render_stop');
        return;
    }

    my $speed = $rc->{speed} || 1;
    my $delay = int(400 / $speed);
    $delay = 16 if $delay < 16;

    $self->{_replay_after} = $self->{canvas}->after($delay, sub {
        $self->{_replay_after} = undef;
        $self->_replay_run_handler('tick', sub {
            my $r = $self->{replay_controller};
            return unless $r && $r->{playing};

            my $n = $self->_replay_raw_total();
            if ($n <= 0 || $r->{current_index} >= $n - 1) {
                $r->stop();
                $self->render();
                return;
            }

            $r->step_forward($n);
            $self->_replay_apply();
            $self->_replay_schedule_tick();
        });
    });
}

# ── Redimensionado ────────────────────────────────────────────────────────────

# resize($width, $height)
# Adapta el motor y todas las escalas al tamano real del canvas. Se invoca
# desde el evento <Configure>. Mantiene la cantidad de velas visibles
# (current_visible_bars) recalculando el ancho de cada vela para llenar el
# nuevo ancho, y reparte la altura entre el panel de precios y el panel ATR
# conservando la proporcion original del ATR.

1;

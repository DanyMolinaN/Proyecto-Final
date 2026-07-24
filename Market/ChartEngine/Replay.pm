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

# _refresh_structure_zigzag()
# Actualiza ZigZag incrementalmente (sin Liquidity/FVG). Solo se invoca cuando
# avanza el puntero de replay o al salir de replay — nunca en pan/zoom/render.
sub _refresh_structure_zigzag {
    my ($self) = @_;
    return unless $self->{smc_structure_engine} && $self->{market_data};

    my %args = (
        replay_controller => $self->{replay_controller},
        timeframe         => $self->{active_tf} || $self->{market_data}->active_tf(),
    );

    my $smc_structure_data = $self->{smc_structure_engine}->calculate(
        $self->{market_data}, %args,
    );
    if ( $self->{analysis_cache} && $smc_structure_data && ref $smc_structure_data eq 'HASH' ) {
        $self->{analysis_cache}{smc_structure} = $smc_structure_data;
        $self->{analysis_cache}{structure} = $self->_legacy_structure_view_from_smc($smc_structure_data);
        if ($self->{analysis_cache}{liquidity}) {
            $self->{analysis_cache}{liquidity}{eq_levels}
                = $self->_eq_levels_from_smc_structure($smc_structure_data);
        }
    }

    if ($self->{engine_registry}) {
        my $zzmtf_eng = $self->{engine_registry}->get('zzmtf_overlay');
        if ($zzmtf_eng) {
            my $view_end = $self->{replay_controller} && $self->{replay_controller}->is_active() ? $self->{replay_controller}->{current_index} : undef;
            my $zzmtf_data = $zzmtf_eng->calculate($self->{market_data}, %args, view_end => $view_end, overlay_settings => $self->{overlay_settings});
            if ($self->{analysis_cache} && $zzmtf_data) {
                $self->{analysis_cache}{zzmtf_overlay} = $zzmtf_data;
            }
        }
    }

    return $smc_structure_data;
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
    my $total = $self->{market_data}->size();
    return unless $total > 0;
    $idx = 0 unless defined $idx;
    $idx = 0 if $idx < 0;
    $idx = $total - 1 if $idx >= $total;

    $self->_cancel_replay_timer();
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
        my $total = $self->{market_data}->size();
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
        $self->_refresh_structure_zigzag();
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

        my $total = $self->{market_data}->size();
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
        my $total = $self->{market_data}->size();
        return unless $total > 0;

        my $target = int($val + 0.5);
        $target = 0 if $target < 0;
        $target = $total - 1 if $target >= $total;
        return if defined $rc->{current_index} && $target == $rc->{current_index};

        $rc->pause();
        $self->_cancel_replay_timer();
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
    my $total = $self->{market_data} ? $self->{market_data}->size() : 0;

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

        my $total = $self->{market_data}->size();
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
        $rc->step_backward();
        $self->_replay_apply();
    });
}

sub _replay_fast_forward {
    my ($self) = @_;
    return $self->_replay_run_handler('fast_forward', sub {
        my $rc = $self->{replay_controller};
        return unless $rc && $rc->is_active();

        my $total = $self->{market_data}->size();
        $rc->pause();
        $self->_cancel_replay_timer();
        $rc->fast_forward(10, $total);
        $self->_replay_apply();
    });
}

sub _replay_schedule_tick {
    my ($self) = @_;
    my $rc = $self->{replay_controller};
    return unless $rc && $rc->{playing} && $self->{canvas};
    $self->_cancel_replay_timer();

    my $total = $self->{market_data}->size();
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

            my $n = $self->{market_data}->size();
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

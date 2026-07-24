package Market::ChartEngine;

# =============================================================================
# Market::ChartEngine::Controls
# =============================================================================
# Panel de controles de indicadores/overlays y estado de botones.
# Continuacion del paquete Market::ChartEngine (split por SRP; sin cambio de API).
# Cargado desde Market::ChartEngine via require.
# =============================================================================

use strict;
use warnings;

sub build_control_panel {
    my ($self, $main_window) = @_;
    return unless $main_window;

    my $bg = '#1e222d';
    my $fg = '#e0e3ea';

    my $panel = $main_window->Frame(-background => $bg)->pack(
        -side => 'top', -fill => 'x', -padx => 4, -pady => 2,
    );

    my $replay_frame = $panel->Labelframe(
        -text      => ' Replay ',
        -background => $bg,
        -fg        => $fg,
        -font      => 'Helvetica 9 bold',
    )->pack(-side => 'left', -padx => 4);

    my @replay_btns = (
        ['Seleccionar', sub { $self->_replay_select_start(); }],
        ['Inicio',  sub { $self->_replay_enter(); }],
        ['Play/Pausa', sub { $self->_replay_toggle_play(); }],
        ['<<',      sub { $self->_replay_step_backward(); }],
        ['>>',      sub { $self->_replay_step_forward(); }],
        ['FF >>',   sub { $self->_replay_fast_forward(); }],
        ['Salir',   sub { $self->_replay_exit(); }],
    );
    for my $btn (@replay_btns) {
        $replay_frame->Button(
            -text     => $btn->[0],
            -command  => $btn->[1],
            -background => '#2a2e39',
            -foreground => $fg,
            -activebackground => '#363a45',
            -font     => 'Helvetica 8',
            -padx     => 6,
            -pady     => 2,
        )->pack(-side => 'left', -padx => 2, -pady => 2);
    }

    # ── Scrubber de recorrido (estilo barra de Replay de TradingView) ──────────
    # Permite saltar a cualquier punto del historico arrastrando el slider,
    # en vez de solo poder avanzar/retroceder vela a vela.
    $self->{_replay_scale} = $replay_frame->Scale(
        -from               => 0,
        -to                 => 1,
        -orient             => 'horizontal',
        -showvalue          => 0,
        -length             => 220,
        -sliderlength       => 14,
        -width              => 10,
        -background         => $bg,
        -troughcolor        => '#2a2e39',
        -foreground         => $fg,
        -highlightthickness => 0,
        -borderwidth        => 0,
        -command            => sub { $self->_replay_seek_scale_changed(@_); },
    )->pack(-side => 'left', -padx => 6, -pady => 2);
    $self->{_replay_scale}->configure(-state => 'disabled');

    # ── Selector de velocidad (0.25x .. 10x) ──────────────────────────────────
    $self->{_replay_speed_var} = 1;
    my @speeds = (0.25, 0.5, 1, 2, 3, 5, 10);
    $self->{_replay_speed_buttons} = {};
    for my $speed (@speeds) {
        my $label = $speed < 1 ? sprintf('%.2fx', $speed) : sprintf('%gx', $speed);
        my $btn = $replay_frame->Button(
            -text             => $label,
            -command          => sub { $self->_replay_set_speed($speed); },
            -background       => $speed == 1 ? '#4d5f2b' : '#2a2e39',
            -foreground       => $fg,
            -activebackground => '#363a45',
            -font             => 'Helvetica 8',
            -padx             => 4,
            -pady             => 2,
        )->pack(-side => 'left', -padx => 1, -pady => 2);
        $self->{_replay_speed_buttons}{$speed} = $btn;
    }
    $self->_replay_sync_controls();

    my $overlay_frame = $panel->Labelframe(
        -text      => ' Indicators ',
        -background => $bg,
        -fg        => $fg,
        -font      => 'Helvetica 9 bold',
    )->pack(-side => 'left', -padx => 8, -fill => 'x', -expand => 1);

    $self->{_overlay_vars} = {};
    $self->{_overlay_btns} = {};          # refs a widgets Checkbutton para _update_button_states
    $self->{_indicator_sections} = {};
    $self->{_price_action_groups} = {};   # subgrupos colapsables solo UI (Price Action)
    my $settings = $self->{overlay_settings};
    my $schema = $settings && $settings->can('schema') ? $settings->schema() : [];
    my %k2o = $self->_key_to_overlay_map();   # key -> nombre de overlay

    for my $category (@$schema) {
        my $cat_label = $category->{label} || $category->{id};
        my $section = $overlay_frame->Frame(-background => $bg)
            ->pack(-side => 'left', -padx => 3, -pady => 2, -anchor => 'n');

        my $header = $section->Button(
            -text       => "$cat_label",
            -relief     => 'flat',
            -background => '#2a2e39',
            -foreground => $fg,
            -activebackground => '#363a45',
            -activeforeground => '#ffffff',
            -font       => 'Helvetica 8 bold',
            -padx       => 7,
            -pady       => 2,
            -command    => sub { $self->_toggle_indicator_section($category->{id}); },
        )->pack(-side => 'top', -fill => 'x');

        my $body = $section->Frame(
            -background => '#171b24',
            -borderwidth => 1,
            -relief => 'flat',
        )->pack(-side => 'top', -fill => 'x');

        $self->{_indicator_sections}{ $category->{id} } = {
            open   => 1,
            header => $header,
            body   => $body,
            label  => $cat_label,
        };

        my @options = @{ $category->{options} || [] };
        if (($category->{id} // '') eq 'price_action') {
            $self->_build_price_action_groups($body, \@options, \%k2o, $settings, $fg);
        }
        else {
            for my $opt (@options) {
                $self->_build_overlay_option_row($body, $opt, \%k2o, $settings, $fg, 0);
            }
        }
    }

    # Actualizar estados de botones segun overlays actualmente registrados.
    $self->_update_button_states();

    return $panel;
}

# Grupos visuales de Price Action (solo UI; keys = mismos IDs del schema).
sub _price_action_ui_groups {
    return (
        { id => 'pa_swings',            label => 'Swings',              keys => [qw(show_swing_high show_swing_low)] },
        { id => 'pa_market_structure',  label => 'Market Structure',    keys => [qw(show_hh show_hl show_lh show_ll)] },
        { id => 'pa_bos',               label => 'Break of Structure',  keys => [qw(show_bos_external show_bos_internal)] },
        { id => 'pa_choch',             label => 'Change of Character', keys => [qw(show_choch_external show_choch_internal)] },
        { id => 'pa_equal_hl',          label => 'Equal High / Low',    keys => [qw(show_eqh show_eql)] },
    );
}

# _build_price_action_groups
# Se fija la altura a 100px para garantizar que entren 4 elementos (Market Structure)
# sin recortarse, manteniendo la estructura general inamovible.
sub _build_price_action_groups {
    my ($self, $parent, $options, $k2o, $settings, $fg) = @_;
    return unless $parent && $options;

    my %opt_by_key = map { $_->[0] => $_ } grep { $_ && ref $_ eq 'ARRAY' && defined $_->[0] } @$options;

    # Altura suficiente para 4 elementos sin cortarlos
    my $fixed_h     = 100;
    my $default_gid = 'pa_market_structure';
    $self->{_price_action_active} = undef;
    $self->{_price_action_slot_h} = $fixed_h;

    for my $group ($self->_price_action_ui_groups()) {
        my $gid   = $group->{id};
        my $label = $group->{label};

        my $group_frame = $parent->Frame(-background => '#171b24')
            ->pack(-side => 'top', -fill => 'x', -pady => 1);

        my $header = $group_frame->Button(
            -text               => '+ ' . $label,
            -relief             => 'flat',
            -background         => '#1c212b',
            -foreground         => '#c5cdd8',
            -activebackground   => '#242936',
            -activeforeground   => '#ffffff',
            -font               => 'Helvetica 8 bold',
            -anchor             => 'w',
            -padx               => 4,
            -pady               => 1,
            -borderwidth        => 0,
            -highlightthickness => 0,
            -command            => sub { $self->_toggle_price_action_group($gid); },
        )->pack(-side => 'top', -fill => 'x');

        # Slot fijo que ocupa los 100px para evitar redimensionamientos
        my $slot = $group_frame->Frame(
            -background => '#171b24',
            -height     => $fixed_h,
        );
        $slot->packPropagate(0);

        my $body = $slot->Frame(-background => '#171b24')
            ->pack(-side => 'top', -anchor => 'nw', -fill => 'x', -padx => [10, 0]);

        for my $key (@{ $group->{keys} || [] }) {
            my $opt = $opt_by_key{$key} or next;
            $self->_build_overlay_option_row($body, $opt, $k2o, $settings, $fg, 1);
        }

        $self->{_price_action_groups}{$gid} = {
            open   => 0,
            header => $header,
            slot   => $slot,
            body   => $body,
            label  => $label,
            frame  => $group_frame,
        };
    }

    # Reserva de espacio para cuando ningún menú esté abierto temporalmente (evita colapso general)
    my $reserve = $parent->Frame(
        -background => '#171b24',
        -height     => $fixed_h,
    );
    $reserve->packPropagate(0);
    $self->{_price_action_reserve} = $reserve;

    # Estado inicial: Market Structure abierto
    $self->_show_price_action_group($default_gid);

    return $self;
}

# _show_price_action_group
sub _show_price_action_group {
    my ($self, $id) = @_;
    return unless $self->{_price_action_groups} && $self->{_price_action_groups}{$id};

    my $active = $self->{_price_action_active};
    if (defined $active && $active eq $id) {
        return $self;
    }

    # Cerrar el anterior
    if (defined $active && $self->{_price_action_groups}{$active}) {
        my $prev = $self->{_price_action_groups}{$active};
        $prev->{slot}->packForget() if $prev->{slot};
        $prev->{open} = 0;
        $prev->{header}->configure(-text => '+ ' . $prev->{label}) if $prev->{header};
    }

    # Ocultar reserva de altura (el slot del grupo activo ya ocupa esos px)
    if ($self->{_price_action_reserve}) {
        $self->{_price_action_reserve}->packForget();
    }

    my $group = $self->{_price_action_groups}{$id};
    my $h = $self->{_price_action_slot_h} || 100;
    if ($group->{slot}) {
        $group->{slot}->configure(-height => $h);
        $group->{slot}->packPropagate(0);
        $group->{slot}->pack(-side => 'top', -fill => 'x', -anchor => 'nw');
    }
    $group->{open} = 1;
    $group->{header}->configure(-text => '- ' . $group->{label}) if $group->{header};
    $self->{_price_action_active} = $id;
    return $self;
}

# _toggle_price_action_group
sub _toggle_price_action_group {
    my ($self, $id) = @_;
    return unless $self->{_price_action_groups} && $self->{_price_action_groups}{$id};
    my $group = $self->{_price_action_groups}{$id};

    if ($group->{open}) {
        $group->{slot}->packForget() if $group->{slot};
        $group->{open} = 0;
        $group->{header}->configure(-text => '+ ' . $group->{label}) if $group->{header};
        $self->{_price_action_active} = undef;

        # Desplegar reserva para mantener altura
        my $reserve = $self->{_price_action_reserve};
        my $h = $self->{_price_action_slot_h} || 100;
        if ($reserve) {
            $reserve->configure(-height => $h);
            $reserve->packPropagate(0);
            $reserve->pack(-side => 'top', -fill => 'x');
        }
        return $self;
    }

    return $self->_show_price_action_group($id);
}

# _build_overlay_option_row
sub _build_overlay_option_row {
    my ($self, $parent, $opt, $k2o, $settings, $fg, $indent) = @_;
    return unless $parent && $opt && ref $opt eq 'ARRAY';

    my ($key, $label) = @$opt;
    return unless defined $key;

    $self->{_overlay_vars}{$key} = $settings->enabled($key);

    my $overlay_name = $k2o->{$key};
    my $available = defined $overlay_name
        ? ($self->{overlay_manager} && $self->{overlay_manager}->get($overlay_name) ? 1 : 0)
        : 0;

    my $btn_fg    = $available ? $fg : '#4a5264';
    my $btn_state = $available ? 'normal' : 'disabled';

    my $row_frame = $parent->Frame(-background => '#171b24')->pack(-side => 'top', -fill => 'x');

    my $btn = $row_frame->Checkbutton(
        -text               => $label,
        -variable           => \$self->{_overlay_vars}{$key},
        -selectcolor        => '#2a2e39',
        -background         => '#171b24',
        -foreground         => $btn_fg,
        -disabledforeground => '#4a5264',
        -activebackground   => '#242936',
        -activeforeground   => '#ffffff',
        -font               => 'Helvetica 8',
        -anchor             => 'w',
        -padx               => $indent ? 2 : 4,
        -pady               => 1,
        -state              => $btn_state,
        -command            => sub {
            $self->set_overlay_option($key, $self->{_overlay_vars}{$key});
        },
    );
    $btn->pack(-side => 'left', -fill => 'x', -anchor => 'w');
    $self->{_overlay_btns}{$key} = $btn;

    # Submenu para ZigZag MTF (Req ZZMTF)
    if ($key eq 'show_zzmtf_internal' || $key eq 'show_zzmtf_external') {
        my $tf_key = $key eq 'show_zzmtf_internal' ? 'zzmtf_internal_tf' : 'zzmtf_external_tf';
        my $tf_val = $settings->values()->{$tf_key} || ($key eq 'show_zzmtf_internal' ? '15m' : '1h');
        $self->{_overlay_vars}{$tf_key} = $tf_val;

        my $tf_frame = $row_frame->Frame(-background => '#171b24')->pack(-side => 'right', -padx => 2);

        for my $opt_tf ('5m', '15m', '30m', '1h', '4h') {
            $tf_frame->Radiobutton(
                -text               => $opt_tf,
                -value              => $opt_tf,
                -variable           => \$self->{_overlay_vars}{$tf_key},
                -indicatoron        => 0,
                -background         => '#2a2e39',
                -foreground         => '#e0e3ea',
                -selectcolor        => '#42a5f5',
                -activebackground   => '#363a45',
                -activeforeground   => '#ffffff',
                -font               => 'Helvetica 7 bold',
                -padx               => 3,
                -pady               => 0,
                -borderwidth        => 0,
                -command            => sub {
                    $self->set_overlay_option($tf_key, $self->{_overlay_vars}{$tf_key});
                }
            )->pack(-side => 'left', -padx => 1);
        }
    }

    # LuxAlgo: Swing/Internal OB Count (1/3/5/10), default 5.
    if ($key eq 'show_ob_external' || $key eq 'show_ob_internal') {
        my $count_key = $key eq 'show_ob_external' ? 'ob_external_count' : 'ob_internal_count';
        my $count_val = $settings->values()->{$count_key};
        $count_val = 5 unless defined $count_val && "$count_val" =~ /^\d+$/;
        $self->{_overlay_vars}{$count_key} = 0 + $count_val;

        my $cnt_frame = $row_frame->Frame(-background => '#171b24')->pack(-side => 'right', -padx => 2);
        for my $n (1, 3, 5, 10) {
            $cnt_frame->Radiobutton(
                -text               => "$n",
                -value              => $n,
                -variable           => \$self->{_overlay_vars}{$count_key},
                -indicatoron        => 0,
                -background         => '#2a2e39',
                -foreground         => '#e0e3ea',
                -selectcolor        => '#42a5f5',
                -activebackground   => '#363a45',
                -activeforeground   => '#ffffff',
                -font               => 'Helvetica 7 bold',
                -padx               => 3,
                -pady               => 0,
                -borderwidth        => 0,
                -command            => sub {
                    $self->set_overlay_option($count_key, $self->{_overlay_vars}{$count_key});
                }
            )->pack(-side => 'left', -padx => 1);
        }
    }

    return $btn;
}

sub _toggle_indicator_section {
    my ($self, $id) = @_;
    return unless $self->{_indicator_sections} && $self->{_indicator_sections}{$id};
    my $section = $self->{_indicator_sections}{$id};
    my $body = $section->{body};
    return unless $body;

    if ($section->{open}) {
        $body->packForget();
        $section->{open} = 0;
    }
    else {
        $body->pack(-side => 'top', -fill => 'x');
        $section->{open} = 1;
    }
    return $self;
}

# set_overlay_option
sub set_overlay_option {
    my ($self, $key, $enabled) = @_;
    return unless $self->{overlay_settings};
    $self->{overlay_settings}->set($key, $enabled);
    $self->{overlay_settings}->save() if $self->{overlay_settings}->can('save');
    $self->_sync_overlay_layer_state();
    $self->render();
    return $self;
}

# set_overlay_enabled
sub set_overlay_enabled {
    my ($self, $name, $enabled) = @_;
    return unless $self->{overlay_manager};
    if ($enabled) {
        $self->{overlay_manager}->enable($name) if $self->{overlay_manager}->can('enable');
    }
    else {
        $self->{overlay_manager}->disable($name) if $self->{overlay_manager}->can('disable');
    }
    $self->render();
    return $self;
}

sub _sync_overlay_layer_state {
    my ($self) = @_;
    return unless $self->{overlay_manager} && $self->{overlay_settings};
    my $s = $self->{overlay_settings};

    my $structure_on =
        $s->enabled('show_swing_high') || $s->enabled('show_swing_low')
        || $s->enabled('show_hh') || $s->enabled('show_hl')
        || $s->enabled('show_lh') || $s->enabled('show_ll')
        || $s->enabled('show_bos_external') || $s->enabled('show_bos_internal')
        || $s->enabled('show_choch_external') || $s->enabled('show_choch_internal')
        || $s->enabled('show_internal_zigzag') || $s->enabled('show_external_zigzag')
        || $s->enabled('show_internal_swings') || $s->enabled('show_external_swings');

    my $liquidity_on =
        $s->enabled('show_liquidity_levels')
        || $s->enabled('show_internal_liquidity') || $s->enabled('show_external_liquidity')
        || $s->enabled('show_sweeps') || $s->enabled('show_grabs') || $s->enabled('show_runs')
        || $s->enabled('show_eqh')   || $s->enabled('show_eql');

    my $fvg_on            = $s->enabled('show_fvg');
    my $orderblock_on     = $s->enabled('show_ob_external') || $s->enabled('show_ob_internal');
    my $volume_profile_on = $s->enabled('show_volume_profile');
    my $anchored_vwap_on  = $s->enabled('show_anchored_vwap');
    my $dynamic_vwap_on   = $s->enabled('show_dynamic_vwap');
    my $fibonacci_on      = $s->enabled('show_fibonacci');
    my $supply_demand_on  = $s->enabled('show_supply_demand');
    my $trend_channel_on      = $s->enabled('show_trend_channel');
    
    my $trailing_extremes_on = $s->enabled('show_strong_weak_hl');
    my $premium_discount_on  = $s->enabled('show_premium_discount');
    my $mtf_levels_on        = $s->enabled('show_daily_levels') || $s->enabled('show_weekly_levels') || $s->enabled('show_monthly_levels');

    for my $pair (
        [structure     => $structure_on],
        [liquidity     => $liquidity_on],
        [fvg           => $fvg_on],
        [orderblock    => $orderblock_on],
        [volume_profile => $volume_profile_on],
        [anchored_vwap => $anchored_vwap_on],
        [dynamic_vwap  => $dynamic_vwap_on],
        [fibonacci     => $fibonacci_on],
        [supply_demand => $supply_demand_on],
        [trend_channel     => $trend_channel_on],
        [trailing_extremes => $trailing_extremes_on],
        [premium_discount  => $premium_discount_on],
        [mtf_levels        => $mtf_levels_on],
    ) {
        my ($name, $on) = @$pair;
        if ($on) {
            $self->{overlay_manager}->enable($name)  if $self->{overlay_manager}->can('enable');
        }
        else {
            $self->{overlay_manager}->disable($name) if $self->{overlay_manager}->can('disable');
        }
    }
    return $self;
}

# _key_to_overlay_map
sub _key_to_overlay_map {
    my ($self) = @_;
    return (
        show_swing_high         => 'structure',
        show_swing_low          => 'structure',
        show_hh                 => 'structure',
        show_hl                 => 'structure',
        show_lh                 => 'structure',
        show_ll                 => 'structure',
        show_bos_external       => 'structure',
        show_bos_internal       => 'structure',
        show_choch_external     => 'structure',
        show_choch_internal     => 'structure',
        show_eqh                => 'liquidity',
        show_eql                => 'liquidity',
        show_internal_zigzag    => 'structure',
        show_external_zigzag    => 'structure',
        show_internal_swings    => 'structure',
        show_external_swings    => 'structure',
        show_trend_channel          => 'trend_channel',
        show_liquidity_levels   => 'liquidity',
        show_internal_liquidity => 'liquidity',
        show_external_liquidity => 'liquidity',
        show_sweeps             => 'liquidity',
        show_grabs              => 'liquidity',
        show_runs               => 'liquidity',
        show_fvg                => 'fvg',
        show_ob_external        => 'orderblock',
        show_ob_internal        => 'orderblock',
        ob_external_count       => 'orderblock',
        ob_internal_count       => 'orderblock',
        show_fibonacci          => 'fibonacci',
        show_supply_demand      => 'supply_demand',
        show_strong_weak_hl     => 'trailing_extremes',
        show_premium_discount   => 'premium_discount',
        show_daily_levels       => 'mtf_levels',
        show_weekly_levels      => 'mtf_levels',
        show_monthly_levels     => 'mtf_levels',
        show_zzmtf_internal     => 'zzmtf_overlay',
        show_zzmtf_external     => 'zzmtf_overlay',
        show_anchored_vwap      => 'anchored_vwap',
        show_dynamic_vwap       => 'dynamic_vwap',
        show_volume_profile     => 'volume_profile',
        show_signals            => undef,
        show_entries            => undef,
    );
}

# _update_button_states
sub _update_button_states {
    my ($self) = @_;
    return unless $self->{_overlay_btns} && $self->{overlay_manager};
    my %k2o = $self->_key_to_overlay_map();
    for my $key (keys %{ $self->{_overlay_btns} }) {
        my $btn = $self->{_overlay_btns}{$key};
        next unless $btn && $btn->can('configure');
        my $overlay_name = $k2o{$key};
        my $available = defined $overlay_name
            ? ($self->{overlay_manager}->get($overlay_name) ? 1 : 0)
            : 0;
        eval { $btn->configure(-state => $available ? 'normal' : 'disabled'); };
    }
    return $self;
}

1;
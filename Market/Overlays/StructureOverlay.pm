package Market::Overlays::StructureOverlay;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Overlays::RenderPolicy;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data            => undef,
        canvas          => $args{canvas},
        scale           => $args{scale},
        settings        => $args{settings},
        elements        => [],
        show_internal   => 0,
        style           => {
            font        => 'Helvetica 7 bold',
            pad_x       => 3,
            pad_y       => 1,
            text_w      => 5,
            text_h      => 10,
            bull_fg     => '#8ee6a8',
            bull_bg     => '#13251a',
            bear_fg     => '#ff9b9b',
            bear_bg     => '#2a1414',
            eq_fg       => '#ffd76a',
            eq_bg       => '#282410',
            neutral_fg  => '#b8c7d1',
            neutral_bg  => '#161d22',
            internal_fg => '#8fa1aa',
            internal_bg => '#121518',
        },
        %args,
    };
    bless $self, $class;
    return $self;
}

sub set_data {
    my ($self, $data) = @_;
    $self->{data} = $data;
    return $self;
}

sub draw {
    my ($self, %args) = @_;
    my $canvas      = $args{canvas} || $self->{canvas};
    my $scale       = $args{scale}  || $self->{scale};
    my $data        = $args{data}   || $self->{data};
    my $market_data = $args{market_data};
    my $start_idx   = $args{start_idx};
    my $end_idx     = $args{end_idx};
    my $clip_y_top    = $args{clip_y_top};
    my $clip_y_bottom = $args{clip_y_bottom};
    return unless $canvas && $scale;
    return unless $data && ref($data) eq 'HASH';

    $self->clear($canvas);

    my $settings = $self->{settings};
    my $swings  = $data->{external_swings} || $data->{swings}  || [];
    my $internal_swings = $data->{internal_swings} || [];
    my $external_swings = $data->{external_swings} || $swings;
    my $breaks  = ref($data->{breaks})  eq 'ARRAY' ? $data->{breaks}  : [];
    my $changes = ref($data->{changes}) eq 'ARRAY' ? $data->{changes} : [];

    # Soporte transparente para SMCStructureEngine (v2)
    if (exists $data->{events} && exists $data->{swing_highs}) {
        my @sh = map { { %$_ } } @{$data->{swing_highs} || []};
        my @sl = map { { %$_ } } @{$data->{swing_lows}  || []};
        my @ih = map { { %$_ } } @{$data->{internal_highs} || []};
        my @il = map { { %$_ } } @{$data->{internal_lows}  || []};
        # Normalizar campos: SMC usa 'level' para precio y 'kind' = 'H'/'L'.
        # Preservamos 'label' (HH/HL/LH/LL) que ya viene del SMCStructureEngine.
        # Normalizamos 'kind' a 'high'/'low' para que el offset Y sea correcto.
        for my $s (@sh) {
            $s->{price} = $s->{level};
            $s->{scope} = 'external';
            $s->{type}  = 'swing';
            $s->{kind}  = 'high';  # SMC usa 'H', overlay espera 'high'
        }
        for my $s (@sl) {
            $s->{price} = $s->{level};
            $s->{scope} = 'external';
            $s->{type}  = 'swing';
            $s->{kind}  = 'low';   # SMC usa 'L', overlay espera 'low'
        }
        for my $s (@ih) {
            $s->{price} = $s->{level};
            $s->{scope} = 'internal';
            $s->{type}  = 'swing';
            $s->{kind}  = 'high';
        }
        for my $s (@il) {
            $s->{price} = $s->{level};
            $s->{scope} = 'internal';
            $s->{type}  = 'swing';
            $s->{kind}  = 'low';
        }
        $external_swings = [@sh, @sl];
        $internal_swings = [@ih, @il];
        $swings = $external_swings;

        my @evs = map { { %$_ } } @{$data->{events} || []};
        for my $e (@evs) {
            $e->{type}      = $e->{kind};
            # Normalizar 'direction': SMC usa 'bullish'/'bearish'
            $e->{direction} //= ($e->{dir} // '')  eq 'up' ? 'bullish' : 'bearish'
                if defined $e->{dir};
        }
        $breaks = \@evs;

        my @eqh = map { { %$_ } } @{$data->{eqh} || []};
        my @eql = map { { %$_ } } @{$data->{eql} || []};
        for my $e (@eqh, @eql) {
            $e->{type}  = $e->{kind};
            $e->{price} = $e->{level};
        }
        $changes = [@eqh, @eql];
    }

    my @points  = (@$breaks, @$changes);

    my $show_internal = $self->{show_internal};
    if (exists $data->{metadata} && ref($data->{metadata}) eq 'HASH') {
        $show_internal = $data->{metadata}{show_internal}
            if defined $data->{metadata}{show_internal};
    }

    my $tier = Market::Overlays::RenderPolicy::zoom_tier(scale => $scale);
    my $tentative = {};
    if ( exists $data->{metadata} && ref( $data->{metadata} ) eq 'HASH' ) {
        $tentative = $data->{metadata}{zigzag_tentative} || {};
    }

    if (_enabled($settings, 'show_internal_zigzag')) {
        # MITIGACION AUMENTADA (auditoria 2026-07-20):
        # Swings internos de 50-100 pts detectados; vol 10x-50x promedio.
        # width: 2 -> 3  |  dash: [5,4] -> [6,3]  (segmento mas largo, hueco menor)
        # Mejora la legibilidad del trazado interno durante flash crashes.
        _draw_zigzag(
            $canvas, $scale, $internal_swings,
            $tentative->{internal},
            '#42a5f5', 3, [6, 3], 'overlay_structure_internal',
        );
    }
    if (_enabled($settings, 'show_external_zigzag')) {
        # MITIGACION AUMENTADA (auditoria 2026-07-20):
        # Flash crash Jul-01 07:34: 307 pts en 1 vela (vol 2447).
        # Flash crash Jul-20 11:41: 112 pts en 1 vela (vol 3538).
        # Caida sostenida Jul-20 13:40-14:55: -124 pts consecutivos.
        # width: 3 -> 4  |  color: '#eceff4' -> '#ffffff' (blanco puro, max contraste)
        # Trazo mas grueso y visible para swings externos de alta amplitud.
        _draw_zigzag(
            $canvas, $scale, $external_swings,
            $tentative->{external},
            '#ffffff', 4, undef, 'overlay_structure_external',
        );
    }

    my $cw = $scale->{candle_width} || 8;
    my $tag_offset = 14 + int($cw / 4);

    my @labels;
    my $swing_rendered = 0;
    my $event_rendered = 0;
    my $discarded_viewport = 0;
    my $discarded_internal = 0;
    my $discarded_invalid  = 0;
    my $discarded_clip     = 0;

    my @swing_sources;
    push @swing_sources, @$external_swings if _enabled($settings, 'show_external_swings');
    push @swing_sources, @$internal_swings if _enabled($settings, 'show_internal_swings');

    for my $swing (@swing_sources) {
        next unless $swing && ref($swing) eq 'HASH';

        my $scope = $swing->{scope} // 'external';

        my $idx = $swing->{index};
        next unless defined $idx;
        if (defined $start_idx && $idx < $start_idx) { $discarded_viewport++; next; }
        if (defined $end_idx   && $idx > $end_idx)   { $discarded_viewport++; next; }

        my $price = $swing->{price};
        next unless defined $price;

        my $kind = $swing->{kind} // '';
        my $struct_abbr = $swing->{label} || _swing_abbr($swing->{type});
        # Inferir high/low si el engine solo trae label estructural.
        if ($kind eq '' && $struct_abbr =~ /^(?:HH|LH|SH|EQH)$/i) { $kind = 'high'; }
        if ($kind eq '' && $struct_abbr =~ /^(?:HL|LL|SL|EQL)$/i) { $kind = 'low'; }

        # Etiquetas a dibujar: estructura (HH/HL/...) y/o pivote crudo (SH/SL).
        # Antes SH/SL nunca aparecian porque el SMC ya etiqueta HH/HL/LH/LL.
        my @draw_labels;
        if ($struct_abbr ne '' && $struct_abbr !~ /^(?:SH|SL)$/i
            && _show_swing_label($settings, $struct_abbr))
        {
            push @draw_labels, $struct_abbr;
        }
        if ($kind eq 'high' && _enabled($settings, 'show_swing_high')) {
            push @draw_labels, 'SH';
        }
        if ($kind eq 'low' && _enabled($settings, 'show_swing_low')) {
            push @draw_labels, 'SL';
        }
        next unless @draw_labels;

        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($price);
        my $stack = 0;

        for my $abbr (@draw_labels) {
            my ($fg, $bg) = _swing_colors($abbr, $scope, $self->{style});
            my $base_dy = $kind eq 'high' ? -$tag_offset : $tag_offset;
            my $stack_dy = $kind eq 'high' ? -$stack : $stack;
            my $ty = $y + $base_dy + $stack_dy;
            # En AUTO el padding ya deja margen; si aun asi el tag sale del
            # panel, se recluye en vez de descartarlo (evita etiquetas "perdidas").
            $ty = _clamp_label_y($ty, $clip_y_top, $clip_y_bottom, $scale);
            unless (_y_in_clip($ty, $clip_y_top, $clip_y_bottom)) {
                $discarded_clip++;
                next;
            }

            my $priority = Market::Overlays::RenderPolicy::priority_for(
                kind => 'swing',
                label => $abbr,
                scope => $scope,
            );
            next unless Market::Overlays::RenderPolicy::visible_for_zoom(
                tier => $tier,
                kind => 'swing',
                label => $abbr,
                scope => $scope,
                priority => $priority,
            );

            push @labels, {
                index      => $idx,
                x_base     => $x,
                y_base     => $ty,
                anchor_x   => $x,
                anchor_y   => $y,
                text       => $scope eq 'internal' ? lc($abbr) : $abbr,
                fg         => $fg,
                bg         => $bg,
                priority   => $priority,
                kind       => 'swing',
                scope      => $scope,
                limit_bucket => 'swing',
            };
            $swing_rendered++;
            $stack += 12;
        }
    }

    for my $point (@points) {
        next unless $point && ref($point) eq 'HASH';

        my $idx = _event_index($point);
        unless (defined $idx) { $discarded_invalid++; next; }

        # Cull por intersección de span ∩ viewport (BOS/CHoCH/EQH/EQL).
        # Eventos puntuales siguen filtrando por un solo índice.
        unless (_event_visible_in_viewport($point, $start_idx, $end_idx)) {
            $discarded_viewport++;
            next;
        }

        my $level = defined $point->{level} ? $point->{level}
                  : defined $point->{price} ? $point->{price}
                  : defined $point->{value} ? $point->{value}
                  : undef;

        my $anchor_y = _event_anchor_y($point, $level, $idx, $market_data, $scale);
        unless (defined $anchor_y) { $discarded_invalid++; next; }

        # Normalización solo de render: el engine puede emitir scope=>'swing'.
        my $scope = $point->{scope} // 'external';
        $scope = 'external' if $scope eq 'swing';

        my $label = _event_label($point);
        next unless _show_event_label($settings, $label, $scope);
        my ($fg, $bg) = _event_style($point, $self->{style});

        my ($span_x1, $span_x2, $span_y) = _event_span($point, $scale, $level, $idx, $anchor_y);
        my $x = defined $span_x1 && defined $span_x2
            ? ($span_x1 + $span_x2) / 2
            : $scale->index_to_center_x($idx);
        my $dir = lc($point->{direction} // $point->{new_trend} // '');
        
        my $is_break = ($label =~ /^(?:BOS|CHoCH)/i && defined $span_y) ? 1 : 0;
        my $is_eq    = ($label =~ /^(?:EQH|EQL)/i && defined $point->{start_index} && defined $point->{end_index}) ? 1 : 0;

        if ($is_eq) {
            # Igual que LiquidityOverlay: origen/fin = pivotes iguales;
            # etiqueta centrada en el trazo (no en un extremo).
            my $eq_x1_idx = $point->{prev_index}  // $point->{start_index} // $point->{swing_index};
            my $eq_x2_idx = $point->{end_index}   // $point->{swing_index} // $idx;
            $span_x1 = $scale->index_to_center_x($eq_x1_idx);
            $span_x2 = $scale->index_to_center_x($eq_x2_idx);
            ($span_x1, $span_x2) = ($span_x2, $span_x1) if $span_x2 < $span_x1;
            $span_y  = defined $level ? $scale->value_to_y($level) : $anchor_y;
            $x = ($span_x1 + $span_x2) / 2;
        }

        # Si el span se sale del viewport, centrar la etiqueta en la parte visible.
        if (($is_break || $is_eq) && defined $span_x1 && defined $span_x2
            && (defined $start_idx || defined $end_idx) && $scale)
        {
            my $vis_lo = $span_x1;
            my $vis_hi = $span_x2;
            if (defined $start_idx) {
                my $vx0 = $scale->index_to_center_x($start_idx);
                $vis_lo = $vx0 if defined $vx0 && $vx0 > $vis_lo;
            }
            if (defined $end_idx) {
                my $vx1 = $scale->index_to_center_x($end_idx);
                $vis_hi = $vx1 if defined $vx1 && $vx1 < $vis_hi;
            }
            $x = ($vis_lo + $vis_hi) / 2 if defined $vis_lo && defined $vis_hi && $vis_hi >= $vis_lo;
        }

        my $has_span = $is_break || $is_eq;
        my $dy  = $has_span ? 0 : (($dir eq 'bearish') ? $tag_offset : -$tag_offset);
        my $ty  = ($has_span ? $span_y : $anchor_y) + $dy;
        $ty = _clamp_label_y($ty, $clip_y_top, $clip_y_bottom, $scale);
        unless (_y_in_clip($ty, $clip_y_top, $clip_y_bottom)) {
            $discarded_clip++;
            next;
        }

        my $priority = Market::Overlays::RenderPolicy::priority_for(
            kind  => 'event',
            type  => $point->{type},
            label => $label,
            scope => $scope,
        );

        # Estilo de línea solo por scope: interno punteado, externo sólido.
        # Aplica a BOS y CHoCH por igual (no a EQH/EQL).
        my $is_internal = ($scope eq 'internal');
        my $dash = ($is_break && $is_internal) ? [6, 4] : undef;

        push @labels, {
            index      => $idx,
            x_base     => $x,
            y_base     => $ty,
            anchor_x   => $x,
            anchor_y   => $anchor_y,
            text       => $label,
            fg         => $fg,
            bg         => $bg,
            span       => ($has_span ? {
                x1      => $span_x1,
                x2      => $span_x2,
                y       => $span_y,
                break_x => $is_break ? $scale->index_to_center_x($idx) : undef,
                dash    => $dash,
            } : undef),
            fixed_position => $has_span ? 1 : 0,
            no_group       => $has_span ? 1 : 0,
            priority   => $priority,
            protected  => ($label =~ /^(?:BOS|CHoCH)/i) ? 1 : 0,
            kind       => 'event',
            type       => $point->{type},
            scope      => $scope,
            limit_bucket => ($label =~ /^BOS/i) ? 'bos'
                          : ($label =~ /^CHoCH/i) ? 'choch'
                          : 'event',
        };
        $event_rendered++;
    }

    my $before_policy = scalar(@labels);
    my $zoom_filtered = Market::Overlays::RenderPolicy::filter_for_zoom(
        \@labels,
        scale => $scale,
        tier  => $tier,
    );
    my $limited = Market::Overlays::RenderPolicy::apply_context_limits(
        $zoom_filtered,
        scale    => $scale,
        tier     => $tier,
        settings => $settings,
    );
    my $grouped = Market::Overlays::RenderPolicy::group_nearby(
        $limited,
        scale => $scale,
    );
    @labels = @$grouped;

    my $collision_audit = Market::Overlays::RenderPolicy::resolve_collisions(
        \@labels,
        scale => $scale,
    );
    my $shift_steps = $collision_audit->{shifted} || 0;
    my $collision_count = $collision_audit->{collisions} || 0;

    for my $item (@labels) {
        next if $item->{hidden};
        if ($item->{span}) {
            _draw_event_span($canvas, $item, $self->{style});
        }
        else {
            _draw_leader($canvas, $item->{anchor_x}, $item->{anchor_y},
                $item->{x_base}, $item->{y_base}, $item->{fg});
        }
        _draw_tag($canvas, $item->{x_base}, $item->{y_base},
            $item->{text}, $item->{fg}, $item->{bg}, $self->{style});
    }

    $self->{smc_audit} = {
        total_received        => scalar(@points) + scalar(@$swings),
        swing_labels_rendered => $swing_rendered,
        event_labels_rendered => $event_rendered,
        discarded_by_viewport => $discarded_viewport,
        discarded_internal    => $discarded_internal,
        discarded_invalid     => $discarded_invalid,
        discarded_clip        => $discarded_clip,
        collisions_avoided    => $collision_count,
        shift_steps_applied   => $shift_steps,
        hidden_by_policy      => $before_policy - scalar(@labels),
        hidden_by_collision   => $collision_audit->{hidden} || 0,
        zoom_tier             => $tier,
        rendered              => scalar(@labels),
    };

    return $self;
}

sub _enabled {
    my ($settings, $key) = @_;
    return 1 unless $settings && $settings->can('enabled');
    return $settings->enabled($key);
}

sub _show_swing_label {
    my ($settings, $abbr) = @_;
    my %map = (
        HH  => 'show_hh',
        HL  => 'show_hl',
        LH  => 'show_lh',
        LL  => 'show_ll',
        EQH => 'show_eqh',
        EQL => 'show_eql',
        SH  => 'show_swing_high',
        SL  => 'show_swing_low',
    );
    my $key = $map{$abbr};
    return 1 unless $key;
    return _enabled($settings, $key);
}

sub _show_event_label {
    my ($settings, $label, $scope) = @_;
    $scope //= 'external';
    $scope = 'external' if $scope eq 'swing';

    my $scope_key;
    if ($label =~ /^BOS/i) {
        $scope_key = $scope eq 'internal' ? 'show_bos_internal' : 'show_bos_external';
    }
    elsif ($label =~ /^CHoCH/i) {
        $scope_key = $scope eq 'internal' ? 'show_choch_internal' : 'show_choch_external';
    }
    else {
        return 1;
    }

    # Unicamente los cuatro toggles por scope; sin master show_bos/show_choch.
    if ($settings && $settings->can('values')) {
        my $vals = $settings->values();
        return 0 unless !exists($vals->{$scope_key}) || $vals->{$scope_key};
    }
    return _enabled($settings, $scope_key);
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    if ( $canvas && $canvas->can('delete') ) {
        $canvas->delete('overlay_structure');
        $canvas->delete('overlay_structure_internal');
        $canvas->delete('overlay_structure_external');
    }
    $self->{elements} = [];
    return $self;
}
# Modulos SRP de Market::Overlays::StructureOverlay (misma API).

require 'Market/Overlays/StructureOverlay/ZigZag.pm';
require 'Market/Overlays/StructureOverlay/EventDraw.pm';
require 'Market/Overlays/StructureOverlay/Style.pm';

1;

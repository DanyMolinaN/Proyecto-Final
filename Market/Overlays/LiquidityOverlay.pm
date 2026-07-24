package Market::Overlays::LiquidityOverlay;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Overlays::RenderPolicy;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data => undef,
        canvas => $args{canvas},
        scale => $args{scale},
        settings => $args{settings},
        elements => [],
        object_cache => {},
        style => {
            font       => 'Helvetica 7',
            event_font => 'Helvetica 7 bold',
            pad_x      => 3,
            pad_y      => 1,
            text_w     => 5,
            text_h     => 10,
            bg         => '#14191d',
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

    $canvas->delete('overlay_liquidity_dynamic') if $canvas && $canvas->can('delete');

    my $levels    = $data->{liquidity_levels} || $data->{levels} || [];
    my $eq_levels = $data->{eq_levels} || [];
    my $events    = $data->{events} || [];
    my $settings  = $self->{settings};

    my @labels;
    my %visible_level_ids;
    my $label_count = 0;
    my $tier = Market::Overlays::RenderPolicy::zoom_tier(scale => $scale);

    if (ref($levels) eq 'ARRAY') {
        for my $level (@$levels) {
            next unless $level && ref($level) eq 'HASH';
            my $idx   = $level->{index} // $level->{created_index};
            my $price = $level->{price} // $level->{value};
            next unless defined $idx && defined $price;
            next if defined $start_idx && $idx < $start_idx;
            next if defined $end_idx && $idx > $end_idx;

            my $ltype = $level->{type} // '';
            next if $level->{eq_pair};    # EQH/EQL: linea en bloque eq_levels

            # Master switch: show_liquidity_levels activa todos los niveles
            my $scope = $level->{scope} // 'external';
            my $show_by_master  = _enabled($settings, 'show_liquidity_levels');
            my $show_by_scope   =
                $scope eq 'internal'
                    ? _enabled($settings, 'show_internal_liquidity')
                    : _enabled($settings, 'show_external_liquidity');
            # Un nivel se dibuja si su master O su scope-flag esta activo
            next unless $show_by_master || $show_by_scope;
            # Exclusion explícita por scope cuando solo el flag de scope opuesto esta ON
            next if $scope eq 'internal' && !$show_by_master && !_enabled($settings, 'show_internal_liquidity');
            next if $scope ne 'internal' && !$show_by_master && !_enabled($settings, 'show_external_liquidity');
            my $priority = Market::Overlays::RenderPolicy::priority_for(
                kind  => $scope eq 'internal' ? 'minor_liquidity' : 'liquidity',
                type  => $ltype,
                label => $ltype,
                scope => $scope,
            );
            next unless Market::Overlays::RenderPolicy::visible_for_zoom(
                tier => $tier,
                kind => $scope eq 'internal' ? 'minor_liquidity' : 'liquidity',
                type => $ltype,
                label => $ltype,
                scope => $scope,
                priority => $priority,
            );

            my ($fill, $width, $dash) = _liquidity_visual($level);
            my $price_y = $scale->value_to_y($price);
            my $text_y = $price_y + _liquidity_y_offset($level->{type});
            next unless _y_in_clip($price_y, $clip_y_top, $clip_y_bottom);
            next unless _y_in_clip($text_y, $clip_y_top, $clip_y_bottom);
            my $draw_end_idx = $level->{invalidated_at} // $level->{resolved_at} // $end_idx;
            my $x1     = $scale->index_to_x($idx);
            my $x_end  = defined $draw_end_idx
                ? $scale->index_to_x($draw_end_idx)
                : ($x1 + ($scale->{width} || 800) - ($scale->{y_axis_strip_w} || 66));
            $x_end = $x1 + 8 if $x_end <= $x1;
            my $text_x = $x_end - 4;
            my $level_id = _level_id($level, $idx, $price);
            $visible_level_ids{$level_id} = 1;
            _upsert_level_line($self, $canvas, $level_id, $x1, $price_y, $x_end, $fill, $width, $dash);

            push @labels, {
                index      => $idx,
                x_base     => $text_x,
                y_base     => $text_y,
                text       => ($level->{type} || 'LEV'),
                anchor     => 'e',
                fill       => $fill,
                font       => $self->{style}{font},
                bg         => $self->{style}{bg},
                line       => { x1 => $x1, x2 => $x_end, y => $price_y, dash => $dash },
                type       => 'liquidity',
                priority   => $priority,
                protected  => $scope ne 'internal' ? 1 : 0,
                no_group   => $scope ne 'internal' ? 1 : 0,
                scope      => $scope,
                limit_bucket => 'liquidity',
                level_id   => $level_id,
            };
            $label_count++;
        }
    }

    if (ref($eq_levels) eq 'ARRAY') {
        for my $eq (@$eq_levels) {
            next unless $eq && ref($eq) eq 'HASH';
            my $first_idx  = $eq->{first_index};
            my $second_idx = $eq->{second_index};
            my $price      = $eq->{level} // $eq->{price} // $eq->{value};
            next unless defined $first_idx && defined $second_idx && defined $price;
            next if defined $start_idx && $second_idx < $start_idx;
            next if defined $end_idx && $first_idx > $end_idx;

            my $fill     = _eq_color($eq->{type});
            next if ($eq->{type} || '') eq 'EQH' && !_enabled($settings, 'show_eqh');
            next if ($eq->{type} || '') eq 'EQL' && !_enabled($settings, 'show_eql');
            # Linea del Equal: pivote origen → pivote final (o proyeccion si existe).
            # La etiqueta va exactamente al centro del trazo, nunca en un extremo.
            my $draw_end_idx = $eq->{end_index} // $eq->{invalidated_at} // $eq->{resolved_at} // $second_idx;
            my $x1       = $scale->index_to_center_x($first_idx);
            my $x2       = $scale->index_to_center_x($draw_end_idx);
            ($x1, $x2) = ($x2, $x1) if $x2 < $x1;
            $x2 = $x1 + 8 if $x2 <= $x1;
            my $y        = $scale->value_to_y($price);
            next unless _y_in_clip($y, $clip_y_top, $clip_y_bottom);
            my $xm       = ($x1 + $x2) / 2;

            push @labels, {
                index      => $second_idx,
                x_base     => $xm,
                y_base     => $y,
                line       => { x1 => $x1, x2 => $x2, y => $y },
                text       => $eq->{type} || 'EQ',
                anchor     => 'c',
                fill       => $fill,
                font       => $self->{style}{font},
                bg         => $self->{style}{bg},
                type       => 'eq',
                priority   => Market::Overlays::RenderPolicy::priority_for(
                    kind => 'liquidity',
                    type => $eq->{type},
                    label => $eq->{type},
                    scope => 'external',
                ),
                protected  => 1,
                fixed_position => 1,
                no_group       => 1,
                scope      => 'external',
                limit_bucket => lc($eq->{type} || 'eq'),
            };
            $label_count++;
        }
    }

    if (ref($events) eq 'ARRAY') {
        my @candidates;
        for my $event (@$events) {
            next unless $event && ref($event) eq 'HASH';
            my $sweep = $event->{start};
            next unless defined $sweep;
            next if defined $start_idx && $sweep < $start_idx;
            next if defined $end_idx   && $sweep > $end_idx;

            my $price = _event_price($event, $market_data);
            next unless defined $price;

            push @candidates, {
                event => $event,
                sweep => $sweep,
                price => $price,
            };
        }
        @candidates = sort { $b->{sweep} <=> $a->{sweep} } @candidates;
        my $max_events = Market::Overlays::RenderPolicy::limit_for(
            tier => $tier,
            kind => 'event',
            key => 'render_max_liquidity_events',
            settings => $settings,
        );
        @candidates = @candidates[0 .. $max_events - 1] if @candidates > $max_events;

        for my $item (@candidates) {
            my $event = $item->{event};
            my $idx   = $item->{sweep};
            my $price = $item->{price};

            my $label  = _event_label($event);
            next unless _show_event($settings, $event->{type});
            my $priority = Market::Overlays::RenderPolicy::priority_for(
                kind => lc($event->{type} // 'event'),
                type => $event->{type},
                label => $label,
                scope => $event->{scope} // 'external',
            );
            next unless Market::Overlays::RenderPolicy::visible_for_zoom(
                tier => $tier,
                kind => lc($event->{type} // 'event'),
                type => $event->{type},
                label => $label,
                scope => $event->{scope} // 'external',
                priority => $priority,
                protected => ($event->{type} || '') eq 'Run' ? 1 : 0,
            );
            my $fill   = _event_color($event);
            my $x      = $scale->index_to_center_x($idx);
            my $price_y = $scale->value_to_y($price);
            my $text_y = $price_y + _event_y_offset($event->{type});
            next unless _y_in_clip($price_y, $clip_y_top, $clip_y_bottom);
            next unless _y_in_clip($text_y, $clip_y_top, $clip_y_bottom);
            my $anchor = lc($event->{type} // '') eq 'grab' ? 'n' : 's';
            my $line_y = $price_y + ($anchor eq 'n' ? 6 : -6);

            push @labels, {
                index      => $idx,
                x_base     => $x,
                y_base     => $text_y,
                text       => $label,
                anchor     => $anchor,
                fill       => $fill,
                font       => $self->{style}{event_font},
                bg         => $self->{style}{bg},
                line       => { x => $x, y1 => $price_y, y2 => $line_y },
                type       => 'event',
                event_type => $event->{type},
                priority   => $priority,
                protected  => ($event->{type} || '') eq 'Run' ? 1 : 0,
                scope      => $event->{scope} // 'external',
                limit_bucket => lc($event->{type} || 'event'),
            };
            $label_count++;
        }
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
        if ($item->{type} && $item->{type} eq 'event' && $item->{line}) {
            $item->{line}->{x} = $item->{x_base};
        }
    }

    for my $item (@labels) {
        next if $item->{hidden};
        if ($item->{type} && $item->{type} eq 'liquidity') {
            _draw_tag($canvas, $item, $self->{style});
        }
        elsif ($item->{type} && $item->{type} eq 'eq') {
            my $line = $item->{line};
            if ($line) {
                $canvas->createLine($line->{x1}, $line->{y}, $line->{x2}, $line->{y},
                    -fill => $item->{fill}, -width => 2, -dash => [4, 3], -tags => ['overlay_liquidity_dynamic']);
            }
            # Draw the label tag as well, centered on the line
            _draw_tag($canvas, $item, $self->{style});
        }
        else {
            my $line = $item->{line};
            $canvas->createLine($line->{x}, $line->{y1}, $line->{x}, $line->{y2},
                -fill => $item->{fill}, -width => 1, -tags => ['overlay_liquidity_dynamic']);
            _draw_tag($canvas, $item, $self->{style});
        }
    }

    _hide_stale_level_lines($self, $canvas, \%visible_level_ids);

    $self->{visual_stabilization_audit} = {
        labels_processed       => $label_count,
        shift_steps_applied    => $shift_steps,
        collisions_avoided     => $collision_count,
        hidden_by_policy       => $before_policy - scalar(@labels),
        hidden_by_collision    => $collision_audit->{hidden} || 0,
        zoom_tier              => $tier,
    };

    return $self;
}

sub _enabled {
    my ($settings, $key) = @_;
    return 1 unless $settings && $settings->can('enabled');
    return $settings->enabled($key);
}

sub _show_event {
    my ($settings, $type) = @_;
    $type ||= '';
    return _enabled($settings, 'show_sweeps') if $type eq 'Sweep';
    return _enabled($settings, 'show_grabs')  if $type eq 'Grab';
    return _enabled($settings, 'show_runs')   if $type eq 'Run';
    return 1;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    $canvas->delete('overlay_liquidity') if $canvas && $canvas->can('delete');
    $canvas->delete('overlay_liquidity_dynamic') if $canvas && $canvas->can('delete');
    $self->{elements} = [];
    $self->{object_cache} = {};
    return $self;
}

# Modulos SRP (misma API).
require 'Market/Overlays/LiquidityOverlay/DrawHelpers.pm';

1;
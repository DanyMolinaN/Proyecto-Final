package Market::Overlays::LiquidityOverlay;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Overlays::LabelLayout;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data => undef,
        canvas => $args{canvas},
        scale => $args{scale},
        settings => $args{settings},
        elements => [],
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

    $self->clear($canvas);

    my $levels    = $data->{liquidity_levels} || $data->{levels} || [];
    my $eq_levels = $data->{eq_levels} || [];
    my $events    = $data->{events} || [];
    my $settings  = $self->{settings};

    my @labels;
    my $label_count = 0;

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
            next unless _enabled($settings, 'show_liquidity_levels');
            my $scope = $level->{scope} // 'external';
            next if $scope eq 'internal' && !_enabled($settings, 'show_internal_liquidity');
            next if $scope ne 'internal' && !_enabled($settings, 'show_external_liquidity');

            my $fill   = _liquidity_color($ltype);
            my $price_y = $scale->value_to_y($price);
            my $text_y = $price_y + _liquidity_y_offset($level->{type});
            next unless _y_in_clip($price_y, $clip_y_top, $clip_y_bottom);
            next unless _y_in_clip($text_y, $clip_y_top, $clip_y_bottom);
            my $x1     = $scale->index_to_x($idx);
            my $x_end  = defined $end_idx
                ? $scale->index_to_x($end_idx)
                : ($x1 + ($scale->{width} || 800) - ($scale->{y_axis_strip_w} || 66));
            $x_end = $x1 + 8 if $x_end <= $x1;
            my $text_x = $x1 + 4;

            push @labels, {
                index      => $idx,
                x_base     => $text_x,
                y_base     => $text_y,
                text       => ($level->{type} || 'LEV'),
                anchor     => 'w',
                fill       => $fill,
                font       => $self->{style}{font},
                bg         => $self->{style}{bg},
                line       => { x1 => $x1, x2 => $x_end, y => $price_y, dash => 1 },
                type       => 'liquidity',
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
            my $x1       = $scale->index_to_x($first_idx);
            my $x2       = $scale->index_to_x($second_idx);
            my $y        = $scale->value_to_y($price);
            next unless _y_in_clip($y, $clip_y_top, $clip_y_bottom);
            my $xm       = ($x1 + $x2) / 2;

            $canvas->createLine($x1, $y, $x2, $y,
                -fill => $fill, -width => 2, -dash => [4, 3], -tags => ['overlay_liquidity']);
            # Texto EQH/EQL lo dibuja StructureOverlay; aqui solo la linea guia.
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
        my $max_events = 40;
        @candidates = @candidates[0 .. $max_events - 1] if @candidates > $max_events;

        for my $item (@candidates) {
            my $event = $item->{event};
            my $idx   = $item->{sweep};
            my $price = $item->{price};

            my $label  = _event_label($event);
            next unless _show_event($settings, $event->{type});
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
            };
            $label_count++;
        }
    }

    my $shift_steps = 0;
    my $collision_count = 0;
    ($shift_steps, $collision_count) = Market::Overlays::LabelLayout::resolve_collisions(
        \@labels,
        y_threshold => 10,
        x_step      => 12,
    );

    for my $item (@labels) {
        if ($item->{type} && $item->{type} eq 'event' && $item->{line}) {
            $item->{line}->{x} = $item->{x_base};
        }
    }

    for my $item (@labels) {
        if ($item->{type} && $item->{type} eq 'liquidity') {
            my $line = $item->{line};
            $canvas->createLine($line->{x1}, $line->{y}, $line->{x2}, $line->{y},
                -fill => $item->{fill}, -width => 1,
                -dash => ($line->{dash} ? [4, 3] : undef),
                -tags => ['overlay_liquidity']);
            _draw_tag($canvas, $item, $self->{style});
        }
        else {
            my $line = $item->{line};
            $canvas->createLine($line->{x}, $line->{y1}, $line->{x}, $line->{y2},
                -fill => $item->{fill}, -width => 1, -tags => ['overlay_liquidity']);
            _draw_tag($canvas, $item, $self->{style});
        }
    }

    $self->{visual_stabilization_audit} = {
        labels_processed       => $label_count,
        shift_steps_applied    => $shift_steps,
        collisions_avoided     => $collision_count,
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

sub _draw_tag {
    my ($canvas, $item, $style) = @_;
    return unless $canvas && $item;
    $style ||= {};
    my $text = $item->{text};
    return unless defined $text;

    my $pad_x = $style->{pad_x} || 3;
    my $pad_y = $style->{pad_y} || 1;
    my $w = length($text) * ($style->{text_w} || 5) + $pad_x * 2;
    my $h = ($style->{text_h} || 10) + $pad_y * 2;
    my $x = $item->{x_base};
    my $y = $item->{y_base};
    my $anchor = $item->{anchor} || 'c';
    my $left = $anchor eq 'w' ? $x : $x - $w / 2;
    my $right = $anchor eq 'w' ? $x + $w : $x + $w / 2;

    $canvas->createRectangle(
        $left, $y - $h / 2, $right, $y + $h / 2,
        -fill => $item->{bg} || $style->{bg} || '#14191d',
        -outline => $item->{fill},
        -width => 1,
        -tags => ['overlay_liquidity'],
    );
    $canvas->createText($x, $y,
        -text   => $text,
        -anchor => $anchor,
        -fill   => $item->{fill},
        -font   => $item->{font} || $style->{font} || 'Helvetica 7',
        -tags   => ['overlay_liquidity'],
    );
}

sub _y_in_clip {
    my ($y, $top, $bottom) = @_;
    return 1 unless defined $y;
    return 0 if defined $top    && $y < $top - 4;
    return 0 if defined $bottom && $y > $bottom + 2;
    return 1;
}

sub _liquidity_color {
    my ($type) = @_;
    return '#e53935' if defined $type && $type eq 'BSL';   # Rojo (spec)
    return '#43a047' if defined $type && $type eq 'SSL';   # Verde (spec)
    return '#9c27b0' if defined $type && $type eq 'EQH';
    return '#7b1fa2' if defined $type && $type eq 'EQL';
    return '#4dd0e1';
}

sub _liquidity_y_offset {
    my ($type) = @_;
    return -18 if defined $type && $type eq 'BSL';
    return  18 if defined $type && $type eq 'SSL';
    return 0;
}

sub _eq_color {
    my ($type) = @_;
    return '#9c27b0' if defined $type && $type eq 'EQH';
    return '#7b1fa2' if defined $type && $type eq 'EQL';
    return '#9c27b0';
}

sub _event_y_offset {
    my ($type) = @_;
    return -10 if defined $type && $type eq 'Run';
    return -22 if defined $type && $type eq 'Sweep';
    return  10 if defined $type && $type eq 'Grab';
    return -8;
}

sub _event_label {
    my ($event) = @_;
    if (defined $event->{type} && $event->{type} eq 'Sweep') {
        return ($event->{direction} // '') eq 'down' ? 'SWEEP ↓' : 'SWEEP ↑';
    }
    return 'LQ RUN'  if defined $event->{type} && $event->{type} eq 'Run';
    return 'LQ GRAB' if defined $event->{type} && $event->{type} eq 'Grab';
    return defined $event->{type} ? uc($event->{type}) : 'EVENT';
}

sub _event_color {
    my ($event) = @_;
    if (defined $event->{type} && $event->{type} eq 'Sweep') {
        return ($event->{direction} // '') eq 'down' ? '#43a047' : '#e53935';
    }
    return '#42a5f5' if defined $event->{type} && $event->{type} eq 'Run';   # Azul
    return '#ff9800' if defined $event->{type} && $event->{type} eq 'Grab';  # Naranja
    return '#ff9800';
}

sub _event_price {
    my ($event, $market_data) = @_;
    return $event->{price} if defined $event->{price};
    return $event->{level} if defined $event->{level};
    return $event->{value} if defined $event->{value};
    return undef unless $market_data && $market_data->can('get_candle');

    my $idx = defined $event->{end} ? $event->{end} : $event->{start};
    return undef unless defined $idx;
    my $candle = $market_data->get_candle($idx);
    return undef unless $candle && ref($candle) eq 'HASH';
    return $candle->{close} if defined $candle->{close};
    return $candle->{high} if defined $candle->{high};
    return $candle->{low} if defined $candle->{low};
    return undef;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    $canvas->delete('overlay_liquidity') if $canvas && $canvas->can('delete');
    $self->{elements} = [];
    return $self;
}

1;

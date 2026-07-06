package Market::Overlays::StructureOverlay;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use Market::Overlays::LabelLayout;

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
    my @points  = (@$breaks, @$changes);

    my $show_internal = $self->{show_internal};
    if (exists $data->{metadata} && ref($data->{metadata}) eq 'HASH') {
        $show_internal = $data->{metadata}{show_internal}
            if defined $data->{metadata}{show_internal};
    }

    if (_enabled($settings, 'show_internal_zigzag')) {
        _draw_zigzag($canvas, $scale, $internal_swings, $start_idx, $end_idx,
            '#6f7f89', 1, [2, 3], 'overlay_structure');
    }
    if (_enabled($settings, 'show_external_zigzag')) {
        _draw_zigzag($canvas, $scale, $external_swings, $start_idx, $end_idx,
            '#d8dee9', 2, undef, 'overlay_structure');
    }

    my $cw = $scale->{candle_width} || 8;
    my $tag_offset = 14 + int($cw / 4);

    my @labels;
    my $swing_rendered = 0;
    my $event_rendered = 0;
    my $discarded_viewport = 0;
    my $discarded_internal = 0;
    my $discarded_invalid  = 0;

    my @swing_sources;
    push @swing_sources, @$external_swings if _enabled($settings, 'show_external_swings');
    push @swing_sources, @$internal_swings if _enabled($settings, 'show_internal_swings');

    for my $swing (@swing_sources) {
        next unless $swing && ref($swing) eq 'HASH';
        my $abbr = $swing->{label} || _swing_abbr($swing->{type});
        if ($abbr eq '') {
            $abbr = ($swing->{kind} || '') eq 'high' ? 'SH'
                  : ($swing->{kind} || '') eq 'low'  ? 'SL'
                  : '';
        }
        next if $abbr eq '';
        next unless _show_swing_label($settings, $abbr);

        my $scope = $swing->{scope} // 'external';
        if (!$show_internal && $scope eq 'internal') {
            $discarded_internal++;
            next;
        }

        my $idx = $swing->{index};
        next unless defined $idx;
        if (defined $start_idx && $idx < $start_idx) { $discarded_viewport++; next; }
        if (defined $end_idx   && $idx > $end_idx)   { $discarded_viewport++; next; }

        my $price = $swing->{price};
        next unless defined $price;

        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($price);
        my ($fg, $bg) = _swing_colors($abbr, $scope, $self->{style});
        my $dy = ($swing->{kind} // '') eq 'high' ? -$tag_offset : $tag_offset;
        my $ty = $y + $dy;
        next unless _y_in_clip($ty, $clip_y_top, $clip_y_bottom);

        push @labels, {
            index      => $idx,
            x_base     => $x,
            y_base     => $ty,
            anchor_x   => $x,
            anchor_y   => $y,
            text       => $scope eq 'internal' ? lc($abbr) : $abbr,
            fg         => $fg,
            bg         => $bg,
            priority   => $scope eq 'internal' ? 3 : 5,
            kind       => 'swing',
        };
        $swing_rendered++;
    }

    for my $point (@points) {
        next unless $point && ref($point) eq 'HASH';

        my $idx = _event_index($point);
        unless (defined $idx) { $discarded_invalid++; next; }

        if (defined $start_idx && $idx < $start_idx) { $discarded_viewport++; next; }
        if (defined $end_idx   && $idx > $end_idx)   { $discarded_viewport++; next; }

        my $level = defined $point->{level} ? $point->{level}
                  : defined $point->{price} ? $point->{price}
                  : defined $point->{value} ? $point->{value}
                  : undef;

        my $anchor_y = _event_anchor_y($point, $level, $idx, $market_data, $scale);
        unless (defined $anchor_y) { $discarded_invalid++; next; }

        my $label = _event_label($point);
        next unless _show_event_label($settings, $label);
        my ($fg, $bg) = _event_style($point, $self->{style});

        my $x = $scale->index_to_center_x($idx);
        my $dir = lc($point->{direction} // $point->{new_trend} // '');
        my $dy  = ($dir eq 'bearish') ? $tag_offset : -$tag_offset;
        my $ty  = $anchor_y + $dy;
        next unless _y_in_clip($ty, $clip_y_top, $clip_y_bottom);

        push @labels, {
            index      => $idx,
            x_base     => $x,
            y_base     => $ty,
            anchor_x   => $x,
            anchor_y   => $anchor_y,
            text       => $label,
            fg         => $fg,
            bg         => $bg,
            priority   => 10,
            kind       => 'event',
        };
        $event_rendered++;
    }

    my ($shift_steps, $collision_count) = Market::Overlays::LabelLayout::resolve_collisions(
        \@labels,
        y_threshold => 12,
        x_step      => 14,
    );

    for my $item (@labels) {
        _draw_leader($canvas, $item->{anchor_x}, $item->{anchor_y},
            $item->{x_base}, $item->{y_base}, $item->{fg});
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
        collisions_avoided    => $collision_count,
        shift_steps_applied   => $shift_steps,
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
    my ($settings, $label) = @_;
    return _enabled($settings, 'show_bos') if $label =~ /^BOS/i;
    return _enabled($settings, 'show_choch') if $label =~ /^CHoCH/i;
    return 1;
}

sub _draw_zigzag {
    my ($canvas, $scale, $swings, $start_idx, $end_idx, $fill, $width, $dash, $tag) = @_;
    return unless $canvas && $scale && $swings && ref($swings) eq 'ARRAY';
    my @points;
    for my $s (sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @$swings) {
        next unless $s && ref($s) eq 'HASH';
        my $idx = $s->{index};
        my $price = $s->{price};
        next unless defined $idx && defined $price;
        next if defined $start_idx && $idx < $start_idx - 1;
        next if defined $end_idx && $idx > $end_idx + 1;
        push @points, $scale->index_to_center_x($idx), $scale->value_to_y($price);
    }
    return unless @points >= 4;
    my @args = (
        @points,
        -fill => $fill,
        -width => $width,
        -tags => [$tag],
    );
    push @args, (-dash => $dash) if $dash;
    $canvas->createLine(@args);
}

sub _event_anchor_y {
    my ($point, $level, $idx, $market_data, $scale) = @_;
    if ($market_data && $market_data->can('get_candle') && defined $idx) {
        my $c = $market_data->get_candle($idx);
        if ($c && ref($c) eq 'HASH' && defined $c->{close}) {
            return $scale->value_to_y($c->{close});
        }
    }
    return $scale->value_to_y($level) if defined $level;
    return undef;
}

sub _draw_leader {
    my ($canvas, $x1, $y1, $x2, $y2, $fg) = @_;
    return unless $canvas && defined $x1 && defined $y1 && defined $x2 && defined $y2;
    return if abs($x1 - $x2) < 1 && abs($y1 - $y2) < 1;
    $canvas->createLine($x1, $y1, $x2, $y2,
        -fill => $fg, -width => 1, -dash => [2, 2],
        -tags => ['overlay_structure'],
    );
}

sub _swing_abbr {
    my ($stype) = @_;
    return 'HH'  if $stype eq 'Higher High';
    return 'HL'  if $stype eq 'Higher Low';
    return 'LH'  if $stype eq 'Lower High';
    return 'LL'  if $stype eq 'Lower Low';
    return 'EQH' if $stype eq 'Equal High';
    return 'EQL' if $stype eq 'Equal Low';
    return 'SH'  if $stype eq 'swing_high';
    return 'SL'  if $stype eq 'swing_low';
    return '';
}

sub _swing_colors {
    my ($abbr, $scope, $style) = @_;
    $style ||= {};
    my ($fg, $bg);
    if ($abbr eq 'HH' || $abbr eq 'HL') {
        ($fg, $bg) = ($style->{bull_fg} || '#81c784', $style->{bull_bg} || '#1b3a1f');
    }
    elsif ($abbr eq 'LH' || $abbr eq 'LL') {
        ($fg, $bg) = ($style->{bear_fg} || '#ef9a9a', $style->{bear_bg} || '#3a1b1b');
    }
    elsif ($abbr eq 'EQH' || $abbr eq 'EQL') {
        ($fg, $bg) = ($style->{eq_fg} || '#ffd54f', $style->{eq_bg} || '#3a3218');
    }
    else {
        ($fg, $bg) = ($style->{neutral_fg} || '#b0bec5', $style->{neutral_bg} || '#263238');
    }
    if (($scope // '') eq 'internal') {
        $bg = $style->{internal_bg} || '#1a1a1a';
        $fg = $style->{internal_fg} || '#78909c';
    }
    return ($fg, $bg);
}

sub _event_style {
    my ($point, $style) = @_;
    $style ||= {};
    if ($point->{type} && $point->{type} eq 'BOS') {
        my $bear = lc($point->{direction} // '') eq 'bearish';
        return $bear ? ($style->{bear_fg} || '#ff5252', $style->{bear_bg} || '#3a1515')
                     : ($style->{bull_fg} || '#69f0ae', $style->{bull_bg} || '#153a22');
    }
    if (($point->{type} || '') =~ /CHoCH/i || defined $point->{new_trend}) {
        my $bear = lc($point->{direction} // $point->{new_trend} // '') eq 'bearish';
        return $bear ? ('#ff9800', '#3a2a10') : ('#40c4ff', '#102a3a');
    }
    return ('#ff9800', '#3a2a10');
}

sub _draw_tag {
    my ($canvas, $x, $y, $text, $fg, $bg, $style) = @_;
    return unless $canvas && defined $x && defined $y && defined $text;
    $style ||= {};

    my $pad_x = $style->{pad_x} || 3;
    my $pad_y = $style->{pad_y} || 1;
    my $w = length($text) * ($style->{text_w} || 5) + $pad_x * 2;
    my $h = ($style->{text_h} || 10) + $pad_y * 2;

    $canvas->createRectangle(
        $x - $w / 2, $y - $h / 2, $x + $w / 2, $y + $h / 2,
        -fill => $bg, -outline => $fg, -width => 1,
        -tags => ['overlay_structure'],
    );
    $canvas->createText($x, $y,
        -text   => $text,
        -anchor => 'c',
        -fill   => $fg,
        -font   => $style->{font} || 'Helvetica 7 bold',
        -tags   => ['overlay_structure'],
    );
}

sub _event_index {
    my ($point) = @_;
    return $point->{index} if defined $point->{index};
    return $point->{confirmation_index} if defined $point->{confirmation_index};
    return $point->{event_index} if defined $point->{event_index};
    return $point->{break_index} if defined $point->{break_index};
    return undef;
}

sub _event_label {
    my ($point) = @_;
    return 'BOS' if $point->{type} && $point->{type} eq 'BOS' && !defined $point->{direction};

    if ($point->{type} && $point->{type} eq 'BOS') {
        my $dir = lc($point->{direction} // '');
        return $dir eq 'bullish' ? 'BOS+'
             : $dir eq 'bearish' ? 'BOS-'
             : 'BOS';
    }

    if ($point->{type} && $point->{type} =~ /CHoCH/i) {
        my $dir = lc($point->{direction} // $point->{new_trend} // '');
        return $dir eq 'bullish' ? 'CHoCH+'
             : $dir eq 'bearish' ? 'CHoCH-'
             : 'CHoCH';
    }

    if (defined $point->{previous_trend} || defined $point->{new_trend}) {
        my $new_trend = lc($point->{new_trend} // '');
        return $new_trend eq 'bullish' ? 'CHoCH+'
             : $new_trend eq 'bearish' ? 'CHoCH-'
             : 'CHoCH';
    }

    return defined $point->{type} ? uc($point->{type}) : 'STRUCT';
}

sub _y_in_clip {
    my ($y, $top, $bottom) = @_;
    return 1 unless defined $y;
    return 0 if defined $top    && $y < $top - 8;
    return 0 if defined $bottom && $y > $bottom + 4;
    return 1;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    $canvas->delete('overlay_structure') if $canvas && $canvas->can('delete');
    $self->{elements} = [];
    return $self;
}

1;

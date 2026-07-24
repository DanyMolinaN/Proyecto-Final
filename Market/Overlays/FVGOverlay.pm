package Market::Overlays::FVGOverlay;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data => undef,
        canvas => $args{canvas},
        scale => $args{scale},
        settings => $args{settings},
        elements => [],
        min_strength => 0.08,
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
    my $canvas    = $args{canvas} || $self->{canvas};
    my $scale     = $args{scale}  || $self->{scale};
    my $data      = $args{data}   || $self->{data};
    my $start_idx = $args{start_idx};
    my $end_idx   = $args{end_idx};
    my $clip_y_top    = $args{clip_y_top};
    my $clip_y_bottom = $args{clip_y_bottom};
    return unless $canvas && $scale;
    return unless $data;

    $self->clear($canvas);
    return $self if $self->{settings}
        && $self->{settings}->can('enabled')
        && !$self->{settings}->enabled('show_fvg');

    my $gaps = $data->{gaps} || [];
    return $self unless ref($gaps) eq 'ARRAY';

    my $max_age = 50;
    if ($data->{metadata} && defined $data->{metadata}{max_age_bars}) {
        $max_age = $data->{metadata}{max_age_bars};
    }
    $max_age = 50 if !$max_age || $max_age <= 0;

    my $ref_idx = defined $end_idx ? $end_idx : undef;
    my $min_strength = $self->{min_strength} // 0.08;

    my $total_received = scalar(@$gaps);
    my $discarded_invalid = 0;
    my $discarded_viewport = 0;
    my $discarded_faded = 0;
    my $rendered = 0;
    my $max_render = 60;

    my @draw_gaps;
    for my $gap (@$gaps) {
        next unless $gap && ref($gap) eq 'HASH';
        my $ci = $gap->{created_index} // $gap->{index};
        next unless defined $ci;
        if (defined $end_idx && $ci > $end_idx)   { next; }
        if (defined $start_idx && ($gap->{extend_to} // $ci) < $start_idx) { next; }
        push @draw_gaps, $gap;
    }
    @draw_gaps = sort {
        ($b->{created_index} // 0) <=> ($a->{created_index} // 0)
    } @draw_gaps;

    my $cw = $scale->index_to_center_x(1) - $scale->index_to_center_x(0);
    my $half = $cw > 0 ? $cw / 2 : 2;

    for my $gap (@draw_gaps) {
        next unless $gap && ref($gap) eq 'HASH';
        my $ci   = $gap->{created_index} // $gap->{index};
        my $ei   = $gap->{extend_to}     // $ci;
        my $type = $gap->{type};
        my $top    = $gap->{top};
        my $bottom = $gap->{bottom};
        unless (defined $ci && defined $type && defined $top && defined $bottom) {
            $discarded_invalid++;
            next;
        }

        if (defined $end_idx && $ci > $end_idx)   { $discarded_viewport++; next; }
        if (defined $start_idx && $ei < $start_idx) { $discarded_viewport++; next; }

        my $age = defined $ref_idx ? ($ref_idx - $ci) : ($gap->{age} // 0);
        $age = 0 if $age < 0;
        my $strength = 1 - ($age / $max_age);
        $strength = 0 if $strength < 0;
        $strength = 1 if $strength > 1;
        if ($gap->{filled}) {
            $strength *= defined $gap->{strength} && $gap->{strength} < 1 ? $gap->{strength} : 0.35;
        }
        if ($strength < $min_strength) {
            $discarded_faded++;
            next;
        }

        my $base = $type eq 'bearish' ? [0xef, 0x53, 0x50]
                 :                        [0x26, 0xa6, 0x9a];
        my $fill = _fade_hex($base, $strength);

        my $stip = $strength >= 0.66 ? 'gray50'
                 : $strength >= 0.40 ? 'gray25'
                 :                      'gray12';

        my $x1 = $scale->index_to_center_x($ci) - $half;
        my $draw_end = $ei;
        $draw_end = $end_idx if defined $end_idx && $draw_end > $end_idx;
        my $x2 = $scale->index_to_center_x($draw_end) + $half;
        $x2 = $x1 + ($half * 2) if $x2 <= $x1;

        my $y1 = $scale->value_to_y($top);
        my $y2 = $scale->value_to_y($bottom);
        ($y1, $y2) = ($y2, $y1) if $y1 > $y2;
        next if defined $clip_y_bottom && $y1 > $clip_y_bottom;
        $y2 = $clip_y_bottom if defined $clip_y_bottom && $y2 > $clip_y_bottom;
        next if $y2 <= $y1;

        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $fill,
            -stipple => $stip,
            -outline => $fill,
            -width   => 1,
            -tags    => ['overlay_fvg'],
        );

        if ($strength > 0.15) {
            my $label = $type eq 'bullish' ? 'FVG+' : 'FVG-';
            my $lx = $scale->index_to_center_x($ci) + 2;
            my $ly = ($y1 + $y2) / 2;
            $canvas->createText($lx, $ly,
                -text   => $label,
                -anchor => 'w',
                -fill   => $fill,
                -font   => 'Helvetica 7 bold',
                -tags   => ['overlay_fvg'],
            );
        }
        $rendered++;
        last if $rendered >= $max_render;
    }

    $self->{smc_audit} = {
        total_received        => $total_received,
        discarded_by_viewport => $discarded_viewport,
        discarded_faded       => $discarded_faded,
        discarded_invalid     => $discarded_invalid,
        rendered              => $rendered,
    };

    return $self;
}

sub _fade_hex {
    my ($rgb, $s) = @_;
    $s = 0 if !defined $s || $s < 0;
    $s = 1 if $s > 1;
    my @bg = (0x13, 0x17, 0x22);
    my @o;
    for my $k (0 .. 2) {
        push @o, int($rgb->[$k] * $s + $bg[$k] * (1 - $s));
    }
    return sprintf('#%02x%02x%02x', @o);
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    $canvas->delete('overlay_fvg') if $canvas && $canvas->can('delete');
    $self->{elements} = [];
    return $self;
}

1;

package Market::Overlays::VolumeProfileOverlay;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data     => undef,
        canvas   => $args{canvas},
        scale    => $args{scale},
        elements => [],
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
    my $canvas = $args{canvas} || $self->{canvas};
    my $scale  = $args{scale}  || $self->{scale};
    my $data   = $args{data}   || $self->{data};
    my $clip_y_top    = $args{clip_y_top};
    my $clip_y_bottom = $args{clip_y_bottom};
    return unless $canvas && $scale && $data && ref($data) eq 'HASH';

    my $settings = $args{settings} || $self->{settings};
    if ($settings && $settings->can('enabled')) {
        return $self unless $settings->enabled('show_volume_profile');
    }

    $self->clear($canvas);

    my $bins_ref     = $data->{bins} || [];
    return $self unless ref($bins_ref) eq 'ARRAY' && @$bins_ref;

    my $width      = $scale->{width} || 800;
    my $strip_w    = $scale->{y_axis_strip_w} || 66;
    my $chart_width = $width - $strip_w - 8;
    my $bar_region_width = int($chart_width * 0.18);
    $bar_region_width = 20 if $bar_region_width < 20;
    $bar_region_width = 180 if $bar_region_width > 180;
    my $x_right = $chart_width;
    my $x_left  = $x_right - $bar_region_width;
    
    my $max_volume = $data->{max_total} || 0;
    return $self unless $max_volume > 0;

    my $max_bar_w  = $chart_width * 0.22;
    return $self if $max_bar_w <= 1;

    my $poc_bin_coords = undef;
    my $poc_price_y = undef;

    for my $bin (@$bins_ref) {
        next unless $bin && ref($bin) eq 'HASH';
        my $price_lo = $bin->{price_lo};
        my $price_hi = $bin->{price_hi};
        my $vol      = $bin->{total} || 0;
        next unless defined $price_lo && defined $price_hi;
        next if $vol <= 0;

        my $y1 = $scale->value_to_y($price_hi);
        my $y2 = $scale->value_to_y($price_lo);
        next unless defined $y1 && defined $y2;
        ($y1, $y2) = ($y2, $y1) if $y1 > $y2;
        next unless _y_in_clip($y1, $clip_y_top, $clip_y_bottom) || _y_in_clip($y2, $clip_y_top, $clip_y_bottom);

        my $bar_len = ($vol / $max_volume) * $max_bar_w;
        next if $bar_len <= 0;

        my $buy_len  = $bin->{buy} ? ($bin->{buy} / $vol) * $bar_len : ($bar_len * 0.5);
        my $sell_len = $bar_len - $buy_len;

        my $x3 = $width;
        my $x2 = $x3 - $sell_len;
        my $x1 = $x2 - $buy_len;

        if ($bin->{is_poc}) {
            $poc_bin_coords = { x1 => $x1, x2 => $x3, y1 => $y1, y2 => $y2 };
            $poc_price_y = ($y1 + $y2) / 2;
        }

        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill => '#26a69a', -outline => '#26a69a', -width => 0, -tags => ['overlay_volume_profile'])
            if $buy_len > 0;
        $canvas->createRectangle($x2, $y1, $x3, $y2,
            -fill => '#ef5350', -outline => '#ef5350', -width => 0, -tags => ['overlay_volume_profile'])
            if $sell_len > 0;
    }

    if ($poc_bin_coords) {
        $canvas->createRectangle($poc_bin_coords->{x1}, $poc_bin_coords->{y1}, $poc_bin_coords->{x2}, $poc_bin_coords->{y2},
            -fill => '', -outline => '#ffeb3b', -width => 2, -tags => ['overlay_volume_profile']);
    }

    if (defined $poc_price_y && _y_in_clip($poc_price_y, $clip_y_top, $clip_y_bottom)) {
        $canvas->createLine($x_left, $poc_price_y, $width, $poc_price_y,
            -fill   => '#ffeb3b',
            -width  => 2,
            -dash   => [4, 4],
            -tags   => ['overlay_volume_profile'],
        );
        $canvas->createText($width - 4, $poc_price_y - 6,
            -text   => 'POC',
            -anchor => 'e',
            -fill   => '#ffeb3b',
            -font   => 'Helvetica 8 bold',
            -tags   => ['overlay_volume_profile'],
        );
    }

    if (defined $data->{val_price} && defined $data->{vah_price}) {
        for my $entry (
            ['VAL', $data->{val_price}],
            ['VAH', $data->{vah_price}]
        ) {
            my ($text, $price) = @$entry;
            my $y = $scale->value_to_y($price);
            next unless defined $y;
            next unless _y_in_clip($y, $clip_y_top, $clip_y_bottom);
            my $line_color = '#81d4fa';
            $canvas->createLine($x_left, $y, $x_right, $y,
                -fill   => $line_color,
                -width  => 1,
                -dash   => [2, 4],
                -tags   => ['overlay_volume_profile'],
            );
            $canvas->createText($x_left - 4, $y,
                -text   => $text,
                -anchor => 'e',
                -fill   => $line_color,
                -font   => 'Helvetica 7',
                -tags   => ['overlay_volume_profile'],
            );
        }
    }

    my $nodes = $data->{nodes} || {};
    if (ref $nodes->{hvn} eq 'ARRAY') {
        for my $node (@{ $nodes->{hvn} }) {
            next unless $node && ref $node eq 'HASH' && defined $node->{price};
            my $y = $scale->value_to_y($node->{price});
            next unless defined $y && _y_in_clip($y, $clip_y_top, $clip_y_bottom);
            $canvas->createLine($x_left, $y, $x_right, $y,
                -fill  => '#ff9800',
                -width => 1,
                -dash  => [1, 3],
                -tags  => ['overlay_volume_profile'],
            );
            $canvas->createText($x_left + 2, $y - 6,
                -text   => 'HVN',
                -anchor => 'nw',
                -fill   => '#ff9800',
                -font   => 'Helvetica 7',
                -tags   => ['overlay_volume_profile'],
            );
        }
    }
    if (ref $nodes->{lvn} eq 'ARRAY') {
        for my $node (@{ $nodes->{lvn} }) {
            next unless $node && ref $node eq 'HASH' && defined $node->{price};
            my $y = $scale->value_to_y($node->{price});
            next unless defined $y && _y_in_clip($y, $clip_y_top, $clip_y_bottom);
            $canvas->createLine($x_left, $y, $x_right, $y,
                -fill  => '#9e9e9e',
                -width => 1,
                -dash  => [1, 5],
                -tags  => ['overlay_volume_profile'],
            );
            $canvas->createText($x_left + 2, $y + 6,
                -text   => 'LVN',
                -anchor => 'nw',
                -fill   => '#9e9e9e',
                -font   => 'Helvetica 7',
                -tags   => ['overlay_volume_profile'],
            );
        }
    }

    my $summary = sprintf('VOL PROFILE (%s bins)', scalar(@$bins_ref));
    $canvas->createText($x_left + 4, 12,
        -text   => $summary,
        -anchor => 'nw',
        -fill   => '#ffffff',
        -font   => 'Helvetica 8',
        -tags   => ['overlay_volume_profile'],
    );

    return $self;
}

sub _y_in_clip {
    my ($y, $top, $bottom) = @_;
    return 1 unless defined $y;
    return 0 if defined $top    && $y < $top - 4;
    return 0 if defined $bottom && $y > $bottom + 2;
    return 1;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    return unless $canvas && $canvas->can('delete');
    $canvas->delete('overlay_volume_profile');
    $self->{elements} = [];
    return $self;
}

1;

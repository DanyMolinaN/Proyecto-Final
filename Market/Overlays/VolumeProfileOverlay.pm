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

    $self->clear($canvas);

    my $distribution = $data->{distribution} || {};
    my $bins_ref     = $distribution->{sorted_bins} || [];
    return $self unless ref($bins_ref) eq 'ARRAY' && @$bins_ref;

    my $poc        = $data->{poc} || {};
    my $value_area = $data->{value_area} || {};

    my $width      = $scale->{width} || 800;
    my $strip_w    = $scale->{y_axis_strip_w} || 66;
    my $chart_width = $width - $strip_w - 8;
    my $bar_region_width = int($chart_width * 0.18);
    $bar_region_width = 20 if $bar_region_width < 20;
    $bar_region_width = 180 if $bar_region_width > 180;
    my $x_right = $chart_width;
    my $x_left  = $x_right - $bar_region_width;
    my $max_volume = 0;
    for my $bin (@$bins_ref) {
        next unless $bin && ref($bin) eq 'HASH';
        my $vol = $bin->{volume} || 0;
        $max_volume = $vol if $vol > $max_volume;
    }
    return $self unless $max_volume > 0;

    for my $bin (@$bins_ref) {
        next unless $bin && ref($bin) eq 'HASH';
        my $price = $bin->{price};
        my $vol   = $bin->{volume} || 0;
        next unless defined $price;
        next if $vol <= 0;

        my $y = $scale->value_to_y($price);
        next unless defined $y;
        next unless _y_in_clip($y, $clip_y_top, $clip_y_bottom);

        my $bar_width = int(($vol / $max_volume) * ($bar_region_width - 10));
        $bar_width = 1 if $bar_width < 1;

        my $x1 = $x_right - $bar_width;
        my $x2 = $x_right;

        $canvas->createLine($x1, $y, $x2, $y,
            -fill  => '#4caf50',
            -width => 4,
            -tags  => ['overlay_volume_profile'],
        );
    }

    if (defined $poc->{price}) {
        my $y = $scale->value_to_y($poc->{price});
        if (defined $y && _y_in_clip($y, $clip_y_top, $clip_y_bottom)) {
            $canvas->createLine($x_left, $y, $x_right, $y,
                -fill   => '#ffeb3b',
                -width  => 2,
                -dash   => [4, 4],
                -tags   => ['overlay_volume_profile'],
            );
            $canvas->createText($x_right + 4, $y,
                -text   => 'POC',
                -anchor => 'w',
                -fill   => '#ffeb3b',
                -font   => 'Helvetica 8 bold',
                -tags   => ['overlay_volume_profile'],
            );
        }
    }

    if (defined $value_area->{value_area_low} && defined $value_area->{value_area_high}) {
        for my $label (qw(value_area_low value_area_high)) {
            my $price = $value_area->{$label};
            next unless defined $price;
            my $y = $scale->value_to_y($price);
            next unless defined $y;
            next unless _y_in_clip($y, $clip_y_top, $clip_y_bottom);
            my $line_color = '#81d4fa';
            my $text      = $label eq 'value_area_low' ? 'VAL' : 'VAH';
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

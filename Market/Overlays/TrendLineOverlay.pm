package Market::Overlays::TrendLineOverlay;

use strict;
use warnings;
use Market::Overlays::RenderPolicy;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data     => undef,
        canvas   => $args{canvas},
        scale    => $args{scale},
        settings => $args{settings},
        elements => [],
        style    => {
            bullish_color => '#8ee6a8',
            bearish_color => '#ff9b9b',
            dash          => '-',
            width         => 1,
        }
    };
    bless $self, $class;
    return $self;
}

sub set_data {
    my ($self, $data) = @_;
    $self->{data} = $data;
    return $self;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas = $self->{canvas} unless $canvas;
    return unless $canvas;
    
    for my $id (@{ $self->{elements} }) {
        eval { $canvas->delete($id) };
    }
    $self->{elements} = [];
    return $self;
}

sub _enabled {
    my ($settings, $key) = @_;
    return 0 unless $settings && $settings->can('enabled');
    return $settings->enabled($key) ? 1 : 0;
}

sub draw {
    my ($self, %args) = @_;
    my $canvas = $args{canvas} || $self->{canvas};
    my $scale  = $args{scale}  || $self->{scale};
    return unless $canvas && $scale;

    $self->clear($canvas);
    
    my $data = $args{data} || $self->{data};
    return unless $data && ref $data eq 'HASH';
    my $lines = $data->{active_lines} || [];
    
    return unless _enabled($self->{settings}, 'show_trendline');

    my $view_start = $args{view_start} // $args{start_idx} // 0;
    my $end_idx    = $args{end_idx}    // 0;
    my $x_shift    = $args{x_shift}    || 0;
    my $stride     = $scale->{draw_stride} || 1;

    for my $line (@$lines) {
        # Only draw if part of the line is visible or ends after view_start
        next if $line->{end_index} < $view_start;
        next if $line->{pivot1}->{index} > $end_idx;
        
        my $p1 = $line->{pivot1};
        my $p2 = $line->{pivot2};
        
        my $x1 = Market::Overlays::RenderPolicy::index_to_x($p1->{index}, $view_start, $stride, $x_shift);
        my $y1 = $scale->price_to_y($p1->{price});
        
        my $end = $line->{end_index};
        
        # calculate y2 at end
        my $m = ($p2->{price} - $p1->{price}) / ($p2->{index} - $p1->{index});
        my $b = $p1->{price} - ($m * $p1->{index});
        my $proj_y_end = ($m * $end) + $b;
        
        my $x2 = Market::Overlays::RenderPolicy::index_to_x($end, $view_start, $stride, $x_shift);
        my $y2 = $scale->price_to_y($proj_y_end);
        
        my $color = $line->{type} eq 'bullish' ? $self->{style}->{bullish_color} : $self->{style}->{bearish_color};
        
        # Extend with a dashed line if it's invalidated (optional), but we only draw up to end_index anyway
        # If we wanted to show invalidation, we'd use dash for invalidated lines. For now, solid if active, dashed if invalidated.
        my $dash = $line->{state} eq 'invalidated' ? $self->{style}->{dash} : undef;
        
        my $id = $canvas->createLine(
            $x1, $y1, $x2, $y2,
            -fill => $color,
            -width => $self->{style}->{width},
            -tags => ['overlay_structure', 'trendline']
        );
        if ($dash) {
            $canvas->itemconfigure($id, -dash => $dash);
        }
        
        push @{ $self->{elements} }, $id;
    }
    
    return $self;
}

1;

package Market::Overlays::FibonacciOverlay;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        data => undef,
        canvas => $args{canvas},
        scale => $args{scale},
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
    
    my $settings = $args{settings} || $self->{settings};
    if ($settings && $settings->can('enabled')) {
        return $self unless $settings->enabled('show_fibonacci');
    }

    $self->clear($canvas);
    return $self unless $data && $data->{active};
    
    my $fibs = $data->{active};
    return $self unless @$fibs;
    
    my %colors = (
        '0' => '#787b86',
        '0.236' => '#f44336',
        '0.382' => '#81c784',
        '0.5' => '#4caf50',
        '0.618' => '#81c784',
        '0.786' => '#64b5f6',
        '1' => '#787b86',
    );
    
    for my $fib (@$fibs) {
        my $x1 = $scale->index_to_center_x($fib->{start_index});
        my $x2 = $scale->index_to_center_x($fib->{end_index});
        my $y = $scale->value_to_y($fib->{price});
        
        my $color = $colors{$fib->{level} + 0} || '#999999';
        
        $canvas->createLine($x1, $y, $x2, $y,
            -fill => $color,
            -width => 1,
            -dash => [2, 2],
            -tags => ['overlay_fibonacci'],
        );
        
        $canvas->createText($x2 + 5, $y,
            -text => $fib->{level},
            -anchor => 'w',
            -fill => $color,
            -font => 'Helvetica 7',
            -tags => ['overlay_fibonacci'],
        );
    }
    return $self;
}

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    $canvas->delete('overlay_fibonacci') if $canvas && $canvas->can('delete');
    return $self;
}

1;

package Market::Volume::NodeDetector;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        high_volume_nodes => [],
        low_volume_nodes  => [],
        %args,
    };
    $self->{threshold_factor} //= 1.5;
    bless $self, $class;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{high_volume_nodes} = [];
    $self->{low_volume_nodes}  = [];
    return $self;
}

sub detect_nodes {
    my ($self, $distribution) = @_;
    return {} unless $distribution && ref $distribution->{bins} eq 'HASH';

    my @bins = sort { $a->{price} <=> $b->{price} } values %{ $distribution->{bins} };
    return {} unless @bins;

    my $avg_volume = 0;
    $avg_volume += $_->{volume} for @bins;
    $avg_volume /= @bins;
    return {} unless $avg_volume > 0;

    my $high_threshold = $avg_volume * $self->{threshold_factor};
    my $low_threshold  = $avg_volume / $self->{threshold_factor};

    my @hvn;
    my @lvn;
    for my $bin (@bins) {
        next unless defined $bin->{volume};
        if ($bin->{volume} >= $high_threshold) {
            push @hvn, { price => $bin->{price}, volume => $bin->{volume} };
        }
        elsif ($bin->{volume} <= $low_threshold) {
            push @lvn, { price => $bin->{price}, volume => $bin->{volume} };
        }
    }

    $self->{high_volume_nodes} = \@hvn;
    $self->{low_volume_nodes}  = \@lvn;

    return {
        hvn => $self->{high_volume_nodes},
        lvn => $self->{low_volume_nodes},
    };
}

1;

package Market::Volume::POCCalculator;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = { %args };
    bless $self, $class;
    return $self;
}

sub compute_poc {
    my ($self, $distribution) = @_;
    return {} unless $distribution && ref $distribution->{bins} eq 'HASH';

    my $best_price;
    my $best_volume = -1;
    for my $bin (values %{ $distribution->{bins} }) {
        next unless defined $bin->{volume};
        if ($bin->{volume} > $best_volume) {
            $best_volume = $bin->{volume};
            $best_price  = $bin->{price};
        }
    }

    return {
        price  => $best_price,
        volume => $best_volume > 0 ? $best_volume : 0,
    };
}

1;

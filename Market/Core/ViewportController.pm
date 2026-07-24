package Market::Core::ViewportController;

# =============================================================================
# Market::Core::ViewportController
# =============================================================================
# Esqueleto base para encapsular el viewport del chart en fases futuras.
# =============================================================================

use strict;
use warnings;

=head1 NAME

Market::Core::ViewportController - controlador base del viewport.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        initialized => 0,
        start_index => 0,
        end_index   => 0,
        visible_bars => 0,
        offset => 0,
        x_shift => 0,
        %args,
    };
    bless $self, $class;
    return $self;
}

sub initialize {
    my ($self) = @_;
    $self->{initialized} = 1;
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{start_index} = 0;
    $self->{end_index}   = 0;
    $self->{visible_bars} = 0;
    $self->{offset} = 0;
    $self->{x_shift} = 0;
    return $self;
}

sub dispose {
    my ($self) = @_;
    $self->{initialized} = 0;
    return $self->reset();
}

sub set_window {
    my ($self, %args) = @_;
    $self->{start_index} = $args{start_index} if exists $args{start_index};
    $self->{end_index}   = $args{end_index} if exists $args{end_index};
    $self->{visible_bars} = $args{visible_bars} if exists $args{visible_bars};
    $self->{offset} = $args{offset} if exists $args{offset};
    $self->{x_shift} = $args{x_shift} if exists $args{x_shift};
    return $self;
}

sub get_state {
    my ($self) = @_;
    return {
        initialized => $self->{initialized},
        start_index => $self->{start_index},
        end_index   => $self->{end_index},
        visible_bars => $self->{visible_bars},
        offset      => $self->{offset},
        x_shift     => $self->{x_shift},
    };
}

sub is_initialized {
    my ($self) = @_;
    return $self->{initialized} ? 1 : 0;
}

1;

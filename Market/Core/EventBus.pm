package Market::Core::EventBus;

# =============================================================================
# Market::Core::EventBus
# =============================================================================
# Bus de eventos ligero para futuras integraciones de interacción y estado.
# Mantiene una interfaz mínima y sin lógica funcional real aún.
# =============================================================================

use strict;
use warnings;

=head1 NAME

Market::Core::EventBus - bus de eventos base para la arquitectura futura.

=head1 SYNOPSIS

    my $bus = Market::Core::EventBus->new();
    $bus->initialize();
    $bus->subscribe('viewport.changed', sub { ... });
    $bus->publish('viewport.changed', \%state);

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        initialized => 0,
        subscribers => {},
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

sub subscribe {
    my ($self, $event, $handler) = @_;
    return 0 unless defined $event && defined $handler;
    push @{ $self->{subscribers}->{$event} }, $handler;
    return 1;
}

sub publish {
    my ($self, $event, @payload) = @_;
    return 0 unless defined $event;
    my $handlers = $self->{subscribers}->{$event} || [];
    for my $handler (@$handlers) {
        next unless $handler;
        $handler->(@payload) if ref $handler eq 'CODE';
    }
    return scalar @$handlers;
}

sub reset {
    my ($self) = @_;
    $self->{subscribers} = {};
    return $self;
}

sub dispose {
    my ($self) = @_;
    $self->{subscribers} = {};
    $self->{initialized} = 0;
    return $self;
}

sub is_initialized {
    my ($self) = @_;
    return $self->{initialized} ? 1 : 0;
}

1;

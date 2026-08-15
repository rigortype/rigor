# frozen_string_literal: true

# Top-level driver: declares NO constant of its own, so it adds no declaration to the census.
# It exists only to make Consumer / A::B::Caller / RbsConsumer referenced, leaving NeverUsed as
# the fixture's single genuinely-unreferenced class.
Consumer.new.call
A::B::Caller.new.go
RbsConsumer.new.make

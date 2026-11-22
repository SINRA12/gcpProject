package lab.flightbooking;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;

class BookingServiceTest {

    private final SimpleMeterRegistry registry = new SimpleMeterRegistry();
    private final BookingRequest twoPassengers = new BookingRequest("GA123", 2);

    private double count(String result) {
        var counter = registry.find("bookings").tag("result", result).counter();
        return counter == null ? 0 : counter.count();
    }

    @Test
    void successCountsTheBookingAndTheRevenue() {
        var service = new BookingService(registry, 0, 0, 0, () -> 0.5);

        Booking booking = service.book(twoPassengers, "success", 0);

        assertThat(booking.status()).isEqualTo("CONFIRMED");
        assertThat(booking.amount()).isEqualTo(2 * BookingService.PRICE_PER_PASSENGER);
        assertThat(count("success")).isEqualTo(1);
        assertThat(registry.find("booking.amount").counter().count()).isEqualTo(2 * BookingService.PRICE_PER_PASSENGER);
    }

    @Test
    void declinedCountsTheBookingButNoRevenue() {
        var service = new BookingService(registry, 0, 0, 0, () -> 0.5);

        Booking booking = service.book(twoPassengers, "declined", 0);

        assertThat(booking.status()).isEqualTo("DECLINED");
        assertThat(count("declined")).isEqualTo(1);
        assertThat(registry.find("booking.amount").counter().count()).isZero();
    }

    @Test
    void errorIsCountedThenThrown() {
        var service = new BookingService(registry, 0, 0, 0, () -> 0.5);

        assertThatThrownBy(() -> service.book(twoPassengers, "error", 0))
                .isInstanceOf(SimulatedFailureException.class);
        assertThat(count("error")).isEqualTo(1);
    }

    @Test
    void randomOutcomeFollowsTheConfiguredRates() {
        // 20% errors, 30% declines: 0.1 falls in the error band, 0.4 in the decline band, 0.9 is a success
        var low = new BookingService(registry, 0.2, 0.3, 0, () -> 0.1);
        assertThatThrownBy(() -> low.book(twoPassengers, "random", 0)).isInstanceOf(SimulatedFailureException.class);

        var mid = new BookingService(new SimpleMeterRegistry(), 0.2, 0.3, 0, () -> 0.4);
        assertThat(mid.book(twoPassengers, "random", 0).status()).isEqualTo("DECLINED");

        var high = new BookingService(new SimpleMeterRegistry(), 0.2, 0.3, 0, () -> 0.9);
        assertThat(high.book(twoPassengers, "random", 0).status()).isEqualTo("CONFIRMED");
    }

    @Test
    void everyBookingIsTimed() {
        var service = new BookingService(registry, 0, 0, 0, () -> 0.5);

        service.book(twoPassengers, "success", 0);

        assertThat(registry.find("booking.duration").timer().count()).isEqualTo(1);
    }
}

package lab.flightbooking;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import java.util.UUID;
import java.util.function.DoubleSupplier;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/**
 * Pretends to book a flight and, more importantly, counts what happened. The three meters are
 * what Prometheus scrapes from /actuator/prometheus on port 9090:
 *   bookings_total{result="success|declined|error"}   how many bookings, by outcome
 *   booking_amount_total{currency="IDR"}              revenue, only from successful bookings
 *   booking_duration_seconds_*                        how long a booking took (histogram)
 * Labels stay few and bounded on purpose: never a booking id or a user id.
 */
@Service
public class BookingService {

    static final String SUCCESS = "success";
    static final String DECLINED = "declined";
    static final String ERROR = "error";
    static final long PRICE_PER_PASSENGER = 1_250_000;
    static final String CURRENCY = "IDR";

    private final MeterRegistry registry;
    private final Counter revenue;
    private final Timer duration;
    private final double failureRate;
    private final double declineRate;
    private final long latencyMs;
    private final DoubleSupplier random;

    @Autowired
    public BookingService(MeterRegistry registry,
                          @Value("${booking.failure-rate}") double failureRate,
                          @Value("${booking.decline-rate}") double declineRate,
                          @Value("${booking.latency-ms}") long latencyMs) {
        this(registry, failureRate, declineRate, latencyMs, Math::random);
    }

    BookingService(MeterRegistry registry, double failureRate, double declineRate, long latencyMs,
                   DoubleSupplier random) {
        this.registry = registry;
        this.failureRate = failureRate;
        this.declineRate = declineRate;
        this.latencyMs = latencyMs;
        this.random = random;
        this.revenue = Counter.builder("booking.amount")
                .description("Value of confirmed bookings")
                .tag("currency", CURRENCY)
                .register(registry);
        this.duration = Timer.builder("booking.duration")
                .description("Time to process a booking")
                .publishPercentileHistogram()   // buckets, so p95 works with histogram_quantile
                .register(registry);
    }

    /**
     * @param simulate success, declined or error to force an outcome; anything else picks one at
     *                 random using the configured failure and decline rates
     * @param delayMs  extra delay for this request, on top of the configured latency
     */
    public Booking book(BookingRequest request, String simulate, long delayMs) {
        return duration.record(() -> process(request, simulate, delayMs));
    }

    private Booking process(BookingRequest request, String simulate, long delayMs) {
        pause(latencyMs + delayMs);
        String result = decide(simulate);
        registry.counter("bookings", "result", result).increment();

        if (ERROR.equals(result)) {
            throw new SimulatedFailureException();
        }
        long amount = request.passengers() * PRICE_PER_PASSENGER;
        if (SUCCESS.equals(result)) {
            revenue.increment(amount);
        }
        return new Booking(UUID.randomUUID().toString(), request.flight(), request.passengers(), amount,
                CURRENCY, SUCCESS.equals(result) ? "CONFIRMED" : "DECLINED");
    }

    private String decide(String simulate) {
        switch (simulate) {
            case SUCCESS, DECLINED, ERROR:
                return simulate;
            default:
                double r = random.getAsDouble();
                if (r < failureRate) {
                    return ERROR;
                }
                return r < failureRate + declineRate ? DECLINED : SUCCESS;
        }
    }

    private static void pause(long millis) {
        if (millis <= 0) {
            return;
        }
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}

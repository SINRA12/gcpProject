package lab.flightbooking;

import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Served under the context path /flight/booking (see application.properties). */
@RestController
public class BookingController {

    private static final long MAX_DELAY_MS = 10_000;

    private final BookingService service;
    private final String version;

    public BookingController(BookingService service, @Value("${app.version}") String version) {
        this.service = service;
        this.version = version;
    }

    /** Which version is running and on which pod: handy to watch a rollout or the load balancing. */
    @GetMapping("/")
    public Map<String, String> info() {
        return Map.of(
                "service", "flight-booking-be",
                "version", version,
                "pod", System.getenv().getOrDefault("HOSTNAME", "unknown"));
    }

    /**
     * Try:  curl -X POST -H 'Content-Type: application/json' -d '{"flight":"GA123","passengers":2}' \
     *         'http://LB_IP/flight/booking/bookings'
     * Optional query parameters: simulate=success|declined|error, delayMs=500
     */
    @PostMapping("/bookings")
    public ResponseEntity<?> create(@RequestBody BookingRequest request,
                                    @RequestParam(defaultValue = "random") String simulate,
                                    @RequestParam(defaultValue = "0") long delayMs) {
        if (request.flight() == null || request.flight().isBlank()
                || request.passengers() < 1 || request.passengers() > 9) {
            return ResponseEntity.badRequest().body(Map.of("error", "flight is required and passengers must be 1 to 9"));
        }
        Booking booking = service.book(request, simulate, Math.min(Math.max(delayMs, 0), MAX_DELAY_MS));
        HttpStatus status = "CONFIRMED".equals(booking.status()) ? HttpStatus.CREATED : HttpStatus.PAYMENT_REQUIRED;
        return ResponseEntity.status(status).body(booking);
    }

    @ExceptionHandler(SimulatedFailureException.class)
    public ResponseEntity<Map<String, String>> failed(SimulatedFailureException e) {
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of("error", e.getMessage()));
    }
}

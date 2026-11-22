package lab.flightbooking;

/** Thrown on purpose so the demo can produce HTTP 500s. */
public class SimulatedFailureException extends RuntimeException {

    public SimulatedFailureException() {
        super("simulated failure");
    }
}

package lab.flightbooking;

public record Booking(String id, String flight, int passengers, long amount, String currency, String status) {
}

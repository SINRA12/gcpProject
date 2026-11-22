package lab.flightbooking;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest
@AutoConfigureMockMvc
class BookingControllerTest {

    private static final String BODY = "{\"flight\":\"GA123\",\"passengers\":2}";

    @Autowired
    private MockMvc mvc;

    @Test
    void infoSaysWhoIsRunning() throws Exception {
        mvc.perform(get("/"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.service").value("flight-booking-be"));
    }

    @Test
    void confirmedBookingIs201() throws Exception {
        mvc.perform(post("/bookings").param("simulate", "success").contentType(MediaType.APPLICATION_JSON).content(BODY))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.status").value("CONFIRMED"));
    }

    @Test
    void declinedBookingIs402() throws Exception {
        mvc.perform(post("/bookings").param("simulate", "declined").contentType(MediaType.APPLICATION_JSON).content(BODY))
                .andExpect(status().isPaymentRequired());
    }

    @Test
    void simulatedFailureIs500() throws Exception {
        mvc.perform(post("/bookings").param("simulate", "error").contentType(MediaType.APPLICATION_JSON).content(BODY))
                .andExpect(status().isInternalServerError());
    }

    @Test
    void invalidBookingIs400() throws Exception {
        mvc.perform(post("/bookings").contentType(MediaType.APPLICATION_JSON)
                        .content("{\"flight\":\"GA123\",\"passengers\":0}"))
                .andExpect(status().isBadRequest());
    }
}

const print = @import("std").debug.print;

pub fn main() void {
    // The approximate weight of the Space Shuttle upon liftoff
    // (including boosters and fuel tank) was 4,480,000 lb.
    //
    // We'll convert this weight from pound to kilograms at a
    // conversion of 0.453592kg to the pound.
    const shuttle_weight: f64 = 0.453592 * 4480e6;

    // By default, float values are formatted in scientific
    // notation. Try experimenting with '{d}' and '{d:.3}' to see
    // how decimal formatting works.
    print("Shuttle liftoff weight: {d:.0}kg\n", .{shuttle_weight});
}

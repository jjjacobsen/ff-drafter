const vaxis = @import("vaxis");

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    draft_update,
    tick,
};

pub const Loop = vaxis.Loop(Event);

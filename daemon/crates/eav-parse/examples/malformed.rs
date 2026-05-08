fn main() {
    let src = "*** TODO [#D] Target Shopping
:PROPERTIES:
:LAST_REPEAT: [2026-05-05 Tue 20:22]
:END:
DEADLINE: <2026-05-12 Tue ++1w -0d>
:PROPERTIES:
:LAST_REPEAT: [2026-04-20 Mon 20:13]
:END:
body
";
    use orgize::Org;
    let org = Org::parse(src);
    for h in org.document().headlines() {
        println!("title: {:?}", h.title_raw());
        println!("scheduled: {:?}", h.scheduled().map(|t| t.raw()));
        println!("deadline: {:?}", h.deadline().map(|t| t.raw()));
        println!("section: {:?}", h.section().map(|s| s.raw()));
    }
}

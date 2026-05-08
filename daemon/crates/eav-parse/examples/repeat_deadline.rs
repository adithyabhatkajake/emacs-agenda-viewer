fn main() {
    let src = "* TODO Test
DEADLINE: <2026-05-19 Tue +2m/4m>
:PROPERTIES:
:LAST_REPEAT: [2026-03-19 Thu 08:15]
:END:
body
";
    use orgize::Org;
    use orgize::ast::Headline;
    use orgize::rowan::ast::AstNode;
    let org = Org::parse(src);
    let doc = org.document();
    for h in doc.headlines() {
        println!("title: {:?}", h.title_raw());
        println!("scheduled: {:?}", h.scheduled().map(|t| t.raw()));
        println!("deadline: {:?}", h.deadline().map(|t| t.raw()));
        let props = h.properties();
        println!("properties: {:?}", props.is_some());
        if let Some(p) = props {
            for (k, v) in p.iter() {
                let key: &str = &k;
                let val: &str = &v;
                println!("  {} = {}", key, val);
            }
        }
    }
}

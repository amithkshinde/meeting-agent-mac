# Receiving feedback

The app's **Feedback** page (sidebar, or Help > Send Feedback…) works out of the box: the Send button opens a
pre-filled GitHub issue. There are two optional upgrades. Both are set in `Resources/Info.plist`, so nobody's
address or web address ever has to be written into the source code.

## 1. Email (easy)

Put your address in the `FeedbackEmail` key. Send then opens the person's mail app with the message ready,
addressed to you. Their own address is visible to you, so this route is never anonymous.

    /usr/libexec/PlistBuddy -c 'Set :FeedbackEmail you@example.com' Resources/Info.plist

## 2. An online form (recommended: this is the only fully anonymous route)

Feedback is sent in the background, with no mail app or GitHub account involved. Anonymous feedback has no name
or email in it at all. Named feedback arrives with the person's name and reply address, and you get it by email
and in a Google Sheet. Free, about five minutes:

1. Open https://script.google.com and choose **New project**.
2. Replace the code with this, then save:

        function doPost(e) {
          var d = JSON.parse(e.postData.contents);
          var sheet = SpreadsheetApp.getActiveSpreadsheet() || SpreadsheetApp.create("Meeting Agent feedback");
          var s = sheet.getSheets()[0];
          s.appendRow([new Date(), d.kind, d.rating || "", d.anonymous ? "anonymous" : (d.name || ""),
                       d.anonymous ? "" : (d.email || ""), d.message, d.version, d.details]);
          MailApp.sendEmail(Session.getEffectiveUser().getEmail(), d.subject, d.text,
                            (!d.anonymous && d.email) ? {replyTo: d.email} : {});
          return ContentService.createTextOutput("ok");
        }

   (If the project is not attached to a spreadsheet, create one first with **Extensions > Apps Script** from inside
   a new Google Sheet, and paste the code there instead.)
3. **Deploy > New deployment > Web app**. Execute as: **Me**. Who has access: **Anyone**. Deploy and approve.
4. Copy the web app URL (it starts with `https://script.google.com/macros/s/`) and set it:

        /usr/libexec/PlistBuddy -c 'Set :FeedbackEndpoint https://script.google.com/macros/s/XXXX/exec' Resources/Info.plist

5. Rebuild the app. When you reply to a named piece of feedback, the email has the sender in Reply-To.

Everything people send is also kept on their own Mac in `~/Movies/MeetingAgent/feedback.json`.

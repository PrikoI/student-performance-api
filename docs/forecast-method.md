# Forecast method and evidence

The team documents were read from the supplied ICT_Project/Presentation folder.
Their research highlights timing, course differences, grades/assessment signals and the difference between predictions and interventions.

Primary references:
- Hellas et al. (2018), Predicting Academic Performance: A Systematic Literature Review.
  https://juholeinonen.com/assets/pdf/hellas2018predicting.pdf
  The review motivates validation and explicit reporting, not any particular numerical coefficient below.
- Marbouti, Diefes-Dux & Madhavan (2016), Models for early prediction of at-risk students in a course using standards-based grading.
  https://www.sciencedirect.com/science/article/pii/S0360131516301634
  Relevant course-level assessment framing. Full-text retrieval was blocked during this task; no claim that this implementation reproduces their model.

Implementation: conservative-baseline-v1.
Subject estimate = current_grade if recent assessment missing, otherwise 0.8*current_grade + 0.2*recent_assessment_score, clipped to the selected scale.
The 0.8/0.2 coefficients are an explicit initial engineering assumption, not research-derived or fitted coefficients.
Midterm/final estimates reuse the subject baseline; independent exam-specific prediction needs longitudinal exam data.
Aggregate is credit weighted. GPA converts each subject using that student's configured nonoverlapping score bands.
Only active periods within supplied dates may be forecast.
Year scope requires configured period count and at least two-thirds observed periods; previous completed periods require actual finals.
Program scope additionally requires duration and actual results across at least two-thirds completed years.
Future average follows current observed weighted performance; future course composition is not known.
No confidence interval is fabricated. No accuracy claim is made from eight synthetic profiles.
Next method: backtest against real dated outcomes by student/course, compare persistence baseline versus regression, prevent future-data leakage, report MAE and calibration. No training across other users occurs in this version.


When graded assessment results exist, their points/maximum are converted to the course scale and combined using the saved component weights. Unobserved components use the baseline. Total weights above 100% are rejected. Attendance and unfinished work are shown as illustrative signals rather than unsupported causal adjustments.

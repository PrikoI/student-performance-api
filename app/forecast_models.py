"""Small, dependency-free forecasting models for Perfecta's tabular data.

The models intentionally refuse to participate when their training or validation
data is insufficient. This keeps the deterministic personal forecast as the
safe fallback while the project accumulates labelled outcomes.
"""
import math
from statistics import mean

FEATURES=("current","momentum","attendance","completion","progress")
_MODEL_CACHE={}

def _number(value, fallback):
    try:
        value=float(value)
        return value if math.isfinite(value) else fallback
    except (TypeError,ValueError):
        return fallback

def feature_vector(snapshot):
    current=_number(snapshot.get("current_score_percent"),50)
    recent=_number(snapshot.get("recent_score_percent"),current)
    return [
        current,
        recent-current,
        _number(snapshot.get("attendance_percent"),75),
        _number(snapshot.get("assignment_completion_percent"),70),
        _number(snapshot.get("period_progress_percent"),50),
    ]

def training_rows(reference):
    rows=[]
    for sample in (reference or {}).get("samples",[]):
        current=_number(sample.get("stage1"),None);target=_number(sample.get("final"),None)
        if current is None or target is None:continue
        stage2=_number(sample.get("stage2"),current)
        absences=max(0,_number(sample.get("absences"),5))
        rows.append(([current,stage2-current,max(0,100-min(100,absences*5)),70,66],max(0,min(100,target))))
    for sample in (reference or {}).get("local_samples",[]):
        current=_number(sample.get("stage1"),None);target=_number(sample.get("final"),None)
        if current is None or target is None:continue
        rows.append(([current,0,75,70,50],max(0,min(100,target))))
    return rows

def _candidate_thresholds(values):
    unique=sorted(set(values))
    if len(unique)<2:return []
    mids=[(a+b)/2 for a,b in zip(unique,unique[1:])]
    if len(mids)<=24:return mids
    return [mids[round(i*(len(mids)-1)/23)] for i in range(24)]

def _best_stump(xs,residuals,min_leaf=4):
    best=None
    for feature in range(len(xs[0])):
        for threshold in _candidate_thresholds([row[feature] for row in xs]):
            left=[r for row,r in zip(xs,residuals) if row[feature]<=threshold]
            right=[r for row,r in zip(xs,residuals) if row[feature]>threshold]
            if len(left)<min_leaf or len(right)<min_leaf:continue
            lv,rv=mean(left),mean(right)
            loss=sum((r-(lv if row[feature]<=threshold else rv))**2 for row,r in zip(xs,residuals))
            if best is None or loss<best[0]:best=(loss,feature,threshold,lv,rv)
    return None if best is None else best[1:]

def _stump_value(stump,row):
    feature,threshold,left,right=stump
    return left if row[feature]<=threshold else right

class GradientStumpRegressor:
    def __init__(self,rounds=32,learning_rate=.08):
        self.rounds=rounds;self.learning_rate=learning_rate;self.base=0;self.stumps=[]
    def fit(self,xs,ys):
        self.base=mean(ys);pred=[self.base]*len(ys)
        for _ in range(self.rounds):
            stump=_best_stump(xs,[y-p for y,p in zip(ys,pred)])
            if stump is None:break
            self.stumps.append(stump)
            pred=[p+self.learning_rate*_stump_value(stump,row) for p,row in zip(pred,xs)]
        return self
    def predict_one(self,row):
        return self.base+sum(self.learning_rate*_stump_value(s,row) for s in self.stumps)

class GradientStumpClassifier:
    def __init__(self,rounds=36,learning_rate=.1):
        self.rounds=rounds;self.learning_rate=learning_rate;self.base=0;self.stumps=[]
    @staticmethod
    def _sigmoid(value):
        value=max(-30,min(30,value))
        return 1/(1+math.exp(-value))
    def fit(self,xs,ys):
        prevalence=max(.02,min(.98,mean(ys)))
        self.base=math.log(prevalence/(1-prevalence));scores=[self.base]*len(ys)
        for _ in range(self.rounds):
            residuals=[y-self._sigmoid(score) for y,score in zip(ys,scores)]
            stump=_best_stump(xs,residuals)
            if stump is None:break
            self.stumps.append(stump)
            scores=[score+self.learning_rate*_stump_value(stump,row) for score,row in zip(scores,xs)]
        return self
    def predict_proba_one(self,row):
        score=self.base+sum(self.learning_rate*_stump_value(s,row) for s in self.stumps)
        return self._sigmoid(score)

def _validation(rows,threshold):
    # Deterministic interleaved split preserves the score distribution better
    # than taking one contiguous slice from an externally ordered data set.
    train=[row for i,row in enumerate(rows) if i%5]
    test=[row for i,row in enumerate(rows) if not i%5]
    if len(train)<30 or len(test)<8:return None
    reg=GradientStumpRegressor().fit([x for x,_ in train],[y for _,y in train])
    predictions=[max(0,min(100,reg.predict_one(x))) for x,_ in test]
    mae=mean(abs(y-p) for p,(_,y) in zip(predictions,test))
    baseline=mean(y for _,y in train)
    baseline_mae=mean(abs(y-baseline) for _,y in test)
    labels=[1 if y<threshold else 0 for _,y in train]
    classifier=None
    if 0<sum(labels)<len(labels):
        classifier=GradientStumpClassifier().fit([x for x,_ in train],labels)
    return {"mae":mae,"baseline_mae":baseline_mae,"classifier":classifier}

def multilevel_ml_prediction(snapshot,reference,threshold=60):
    rows=training_rows(reference)
    if len(rows)<40:return None
    # The reference cohort is identical for every subject in one forecast.
    # Training per subject made an eight-course forecast perform the same
    # expensive work eight times and regularly exceed the browser timeout.
    # Keep a small content-addressed cache and only run inference per subject.
    signature=(len(rows),round(sum(y for _,y in rows),4),round(sum(x[0] for x,_ in rows),4),float(threshold))
    trained=_MODEL_CACHE.get(signature)
    if trained is None:
        validation=_validation(rows,threshold)
        if not validation:return None
        xs=[x for x,_ in rows];ys=[y for _,y in rows]
        reg=GradientStumpRegressor().fit(xs,ys)
        risk_labels=[1 if y<threshold else 0 for y in ys]
        classifier=None
        if 0<sum(risk_labels)<len(risk_labels):
            classifier=GradientStumpClassifier().fit(xs,risk_labels)
        trained=(validation,reg,classifier)
        if len(_MODEL_CACHE)>=4:_MODEL_CACHE.clear()
        _MODEL_CACHE[signature]=trained
    validation,reg,classifier=trained
    if not validation:return None
    # An unhelpful validation result is recorded but receives no ensemble weight.
    useful=validation["mae"]<=validation["baseline_mae"]*1.05
    vector=feature_vector(snapshot)
    risk=None if classifier is None else classifier.predict_proba_one(vector)
    return {
        "grade":round(max(0,min(100,reg.predict_one(vector))),2),
        "risk_probability":None if risk is None else round(100*risk,1),
        "sample_count":len(rows),"validation_mae":round(validation["mae"],2),
        "baseline_mae":round(validation["baseline_mae"],2),"eligible":useful,
        "feature_schema":"normalized-academic-v1",
    }
